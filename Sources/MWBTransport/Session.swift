// Sessione MWB: listener sulla porta messaggi (base+1), connessione uscente verso il PC
// con riconnessione automatica, heartbeat, machine pool minimale.
// Fonte: PowerToys `SocketStuff.cs`, `Common.SkSend`, `Receiver.cs`.

import Foundation
import MWBProtocol
import Network

public final class Session: @unchecked Sendable {
    public struct Configuration {
        /// Nome con cui il Mac si presenta (max 32 caratteri ASCII); deve coincidere con
        /// quello inserito nella matrice di PowerToys.
        public var localName: String
        public var machineID: UInt32
        public var securityKey: String
        /// Nome o indirizzo del PC; `nil` = solo ascolto.
        public var remoteHost: String?
        /// Porta base di MWB: appunti sulla base, messaggi sulla base+1.
        public var basePort: UInt16
        /// Porta locale del listener messaggi; `nil` = non ascoltare.
        public var listenPort: UInt16?
        public var heartbeatInterval: TimeInterval
        public var reconnectInterval: TimeInterval
        /// Schema di cifratura; `.auto` lo riconosce dal flusso del PC.
        public var cipherScheme: CipherScheme = .auto
        /// Porta locale del canale appunti (di norma la porta base); `nil` = non ascoltare.
        /// Senza listener il PC ripiega su `ClipboardAsk` e i dati gli vengono spinti.
        public var clipboardListenPort: UInt16?

        public init(localName: String, machineID: UInt32, securityKey: String, remoteHost: String?,
                    basePort: UInt16 = 15100, listenPort: UInt16? = 15101,
                    heartbeatInterval: TimeInterval = 5, reconnectInterval: TimeInterval = 3) {
            self.localName = localName
            self.machineID = machineID
            self.securityKey = securityKey
            self.remoteHost = remoteHost
            self.basePort = basePort
            self.listenPort = listenPort
            self.heartbeatInterval = heartbeatInterval
            self.reconnectInterval = reconnectInterval
        }
    }

    public struct Machine: Equatable, Sendable {
        public let id: UInt32
        public let name: String
    }

    // Le callback arrivano sulla coda della sessione.
    public var onMachineConnected: ((Machine) -> Void)?
    public var onMachineDisconnected: ((Machine) -> Void)?
    public var onPacket: ((Packet) -> Void)?
    /// La security key non coincide con quella del PC; la sessione smette di riprovare.
    public var onInvalidKey: (() -> Void)?
    /// Appunti ricevuti da un'altra macchina (in linea o dal canale appunti).
    public var onClipboardReceived: ((ClipboardPayload, Machine) -> Void)?

    public let log: Log
    private let configuration: Configuration
    private let context: PeerConnection.Context
    private let queue = DispatchQueue(label: "mwbmac.session")
    private var listener: NWListener?
    private var peers: [PeerConnection] = []
    private var pool: [UInt32: Machine] = [:]
    private var timer: DispatchSourceTimer?
    private var nextPacketID = Int32.random(in: 1...0x3FFF_FFFF)
    private var recentIDs = [Int32](repeating: 0, count: 50)
    private var recentIndex = 0
    private var running = false
    private var lastHeartbeat = Date.distantPast
    private var lastConnectAttempt = Date.distantPast
    /// Dopo un flusso illeggibile non si riprova: una raffica di tentativi con la
    /// chiave sbagliata fa scattare le protezioni di PowerToys (`InvalidKeyFound`).
    private var invalidKeyLatched = false

    // Appunti
    private var clipboardListener: NWListener?
    private var transfers: [ClipboardTransfer] = []
    /// Ultimo contenuto copiato sul Mac, offerto a chi lo chiede sul canale appunti.
    private var localClipboard: ClipboardPayload?
    /// Macchine che hanno già ritirato `localClipboard` (se grande).
    private var deliveredTo = Set<UInt32>()
    private var pullsInProgress = Set<UInt32>()
    private var lastReceivedDigest: (digest: Int, time: Date)?
    private var lastScheme = CipherScheme.current

    private let stateLock = NSLock()
    private var connectedSnapshot: [Machine] = []

    public init(configuration: Configuration, log: Log = Log()) {
        let key = KeyDerivation.normalize(securityKey: configuration.securityKey)
        self.configuration = configuration
        self.log = log
        self.context = PeerConnection.Context(securityKey: key,
                                              magic: KeyDerivation.magicNumber(securityKey: key),
                                              localName: configuration.localName,
                                              localID: configuration.machineID,
                                              scheme: configuration.cipherScheme,
                                              legacyKey: (try? KeyDerivation.legacyKey(securityKey: key)) ?? [],
                                              log: log)
    }

    /// Macchine con almeno una connessione fidata (leggibile da qualsiasi thread).
    public var connectedMachines: [Machine] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectedSnapshot
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            startListener()
            startClipboardListener()
            connectIfNeeded()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Invia ByeBye e chiude tutto; ritorna quando la chiusura è stata avviata.
    public func stop() {
        queue.sync { [self] in
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
            broadcast(Packet(type: .byeBye, des: MachineID.all, machineName: configuration.localName))
            listener?.cancel()
            listener = nil
            clipboardListener?.cancel()
            clipboardListener = nil
            transfers.forEach { $0.cancel() }
            let closing = peers
            // Lascia a Network.framework il tempo di svuotare il buffer di invio.
            queue.asyncAfter(deadline: .now() + 0.2) {
                closing.forEach { $0.close(.local) }
            }
        }
    }

    /// Accoda un pacchetto; `Id` e `Src` vengono assegnati qui. Sicuro da qualsiasi thread.
    public func send(_ packet: Packet) {
        queue.async { [self] in
            guard running else { return }
            broadcast(packet)
        }
    }

    // MARK: Invio

    /// Equivalente di `Common.SkSend`: un solo socket per macchina di destinazione
    /// (PowerToys li usa tutti e si affida alla deduplica per Id; uno basta).
    private func broadcast(_ original: Packet) {
        var packet = original
        packet.id = nextID()
        packet.src = configuration.machineID
        var served = Set<UInt32>()
        let ordered = peers.filter { $0.isTrusted && !$0.isClosed }.sorted { $0.isOutgoing && !$1.isOutgoing }
        for peer in ordered where packet.des == MachineID.all || packet.des == peer.remoteID {
            guard served.insert(peer.remoteID).inserted else { continue }
            peer.send(packet)
        }
    }

    private func nextID() -> Int32 {
        nextPacketID = nextPacketID == Int32.max ? 1 : nextPacketID + 1
        return nextPacketID
    }

    // MARK: Connessioni

    private func startListener() {
        guard let port = configuration.listenPort, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: Session.tcpParameters(), on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.adopt(connection, isOutgoing: false)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.log.info("In ascolto sulla porta \(port)")
                case .failed(let error): self?.log.info("Listener sulla porta \(port) fallito: \(error)")
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            log.info("Impossibile aprire il listener sulla porta \(port): \(error)")
        }
    }

    private func connectIfNeeded() {
        guard running, !invalidKeyLatched, let host = configuration.remoteHost, !host.isEmpty else { return }
        guard !peers.contains(where: { $0.isOutgoing && !$0.isClosed }) else { return }
        guard Date().timeIntervalSince(lastConnectAttempt) >= configuration.reconnectInterval else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.basePort + 1) else { return }
        lastConnectAttempt = Date()
        log.debug("Connessione a \(host):\(port)…")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: Session.tcpParameters())
        adopt(connection, isOutgoing: true)
    }

    private static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func adopt(_ connection: NWConnection, isOutgoing: Bool) {
        let peer = PeerConnection(connection: connection, isOutgoing: isOutgoing, context: context, queue: queue)
        peer.onTrusted = { [weak self] peer in self?.peerTrusted(peer) }
        peer.onPacket = { [weak self] packet, peer in self?.received(packet, from: peer) }
        peer.onClosed = { [weak self] peer, reason in self?.peerClosed(peer, reason) }
        peer.onClipboard = { [weak self] payload, peer in self?.receivedClipboard(payload, from: peer.remoteID) }
        peers.append(peer)
        if !isOutgoing { log.debug("Connessione entrante da \(connection.endpoint)") }
        peer.start()
    }

    private func peerTrusted(_ peer: PeerConnection) {
        if peer.remoteID == configuration.machineID {
            log.info("\(peer.label): stesso MachineId del Mac o connessione a se stessi, chiudo")
            peer.close(.local)
            return
        }
        if let scheme = peer.activeScheme { lastScheme = scheme }
        let machine = Machine(id: peer.remoteID, name: peer.remoteName)
        let isNew = pool[machine.id] == nil
        pool[machine.id] = machine
        log.debug("\(peer.label): fidata, macchina \"\(machine.name)\" id \(machine.id)")
        refreshSnapshot()
        // Come `Common.SendHeartBeat(initial: true)` dopo la fiducia.
        sendHeartbeat()
        if isNew {
            log.info("Connesso a \"\(machine.name)\" (id \(machine.id))")
            onMachineConnected?(machine)
        }
    }

    private func peerClosed(_ peer: PeerConnection, _ reason: PeerConnection.CloseReason) {
        peers.removeAll { $0 === peer }
        if case .invalidKey = reason {
            if !invalidKeyLatched {
                log.info("\(peer.label): \(reason). Non riprovo: correggere la chiave con `mwbmac set-key` e rilanciare.")
            }
            invalidKeyLatched = true
            onInvalidKey?()
        } else {
            log.debug("\(peer.label): \(reason)")
        }
        guard peer.isTrusted else { return }
        let stillConnected = peers.contains { $0.isTrusted && $0.remoteID == peer.remoteID }
        if !stillConnected, let machine = pool.removeValue(forKey: peer.remoteID) {
            refreshSnapshot()
            log.info("Connessione con \"\(machine.name)\" persa")
            onMachineDisconnected?(machine)
        }
    }

    private func refreshSnapshot() {
        let machines = pool.values.sorted { $0.id < $1.id }
        stateLock.lock()
        connectedSnapshot = machines
        stateLock.unlock()
    }

    // MARK: Appunti

    /// Pubblica il contenuto appena copiato sul Mac. Fino a 1 MB viaggia subito in linea;
    /// oltre viene annunciato e il PC lo ritira quando il controllo passa a lui.
    /// `activeMachine` è la macchina sotto controllo in questo momento, se c'è: in quel
    /// caso il passaggio è già avvenuto e l'annuncio va accompagnato da `MachineSwitched`.
    public func sendClipboard(_ payload: ClipboardPayload, activeMachine: UInt32? = nil) {
        queue.async { [self] in
            guard running else { return }
            guard payload.data.count <= ClipboardPayload.maxSize else {
                log.info("Appunti non inviati: \(payload.data.count / (1024 * 1024)) MB superano il limite di 100 MB")
                return
            }
            localClipboard = payload
            deliveredTo.removeAll()
            if payload.isInline {
                log.debug("Appunti (\(payload.kind.rawValue), \(payload.data.count) byte) inviati in linea")
                payload.inlinePackets().forEach { broadcast($0) }
            } else {
                log.debug("Appunti (\(payload.kind.rawValue), \(payload.data.count) byte) annunciati")
                announceClipboard()
                if let activeMachine { broadcast(Packet(type: .machineSwitched, des: activeMachine)) }
            }
        }
    }

    /// Da chiamare subito prima di `MachineSwitched`: se la macchina non ha ancora ritirato
    /// gli appunti grandi, l'annuncio viene ripetuto. PowerToys li ritira solo se l'annuncio
    /// è arrivato da meno di 30 secondi (`BIG_CLIPBOARD_DATA_TIMEOUT`).
    public func refreshClipboardOffer(for machineID: UInt32) {
        queue.async { [self] in
            guard running, let payload = localClipboard, !payload.isInline, !deliveredTo.contains(machineID) else { return }
            announceClipboard()
        }
    }

    private func announceClipboard() {
        broadcast(Packet(type: .clipboard, des: MachineID.all, machineName: configuration.localName))
    }

    private func startClipboardListener() {
        guard let port = configuration.clipboardListenPort, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: Session.tcpParameters(), on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.log.debug("Canale appunti: connessione entrante da \(connection.endpoint)")
                self.startTransfer(connection, role: .serve(self.localClipboard))
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.log.info("Listener degli appunti sulla porta \(port) fallito: \(error)")
                }
            }
            listener.start(queue: queue)
            clipboardListener = listener
        } catch {
            log.info("Impossibile aprire il listener degli appunti sulla porta \(port): \(error)")
        }
    }

    private func clipboardConnection(to machineID: UInt32) -> NWConnection? {
        let candidates = peers.filter { $0.isTrusted && !$0.isClosed && $0.remoteID == machineID }
        guard let host = candidates.compactMap(\.remoteHost).first
                ?? configuration.remoteHost.map({ NWEndpoint.Host($0) }),
              let port = NWEndpoint.Port(rawValue: configuration.basePort) else { return nil }
        return NWConnection(host: host, port: port, using: Session.tcpParameters())
    }

    private func pullClipboard(from machineID: UInt32) {
        guard pool[machineID] != nil, !pullsInProgress.contains(machineID),
              let connection = clipboardConnection(to: machineID) else { return }
        pullsInProgress.insert(machineID)
        log.debug("Canale appunti: richiesta dei dati a \(pool[machineID]?.name ?? "?")")
        startTransfer(connection, role: .pull, pullingFrom: machineID)
    }

    private func pushClipboard(to machineID: UInt32) {
        guard let payload = localClipboard, pool[machineID] != nil,
              let connection = clipboardConnection(to: machineID) else { return }
        log.debug("Canale appunti: invio dei dati a \(pool[machineID]?.name ?? "?") su sua richiesta")
        startTransfer(connection, role: .push(payload))
    }

    private func startTransfer(_ connection: NWConnection, role: ClipboardTransfer.Role, pullingFrom: UInt32? = nil) {
        let transfer = ClipboardTransfer(
            connection: connection, role: role, scheme: lastScheme, context: context, queue: queue,
            isKnownMachine: { [weak self] id, _ in self?.pool[id] != nil },
            completion: { [weak self] transfer, outcome in
                guard let self else { return }
                self.transfers.removeAll { $0 === transfer }
                if let pullingFrom { self.pullsInProgress.remove(pullingFrom) }
                switch outcome {
                case .received(let payload, let machineID, _):
                    self.receivedClipboard(payload, from: machineID)
                case .sent(let machineID, let bytes):
                    self.deliveredTo.insert(machineID)
                    self.log.debug("\(transfer.label): inviati \(bytes) byte")
                case .failed(let reason):
                    self.log.debug("\(transfer.label): \(reason)")
                }
            })
        transfers.append(transfer)
        transfer.start()
    }

    private func receivedClipboard(_ payload: ClipboardPayload, from machineID: UInt32) {
        guard let machine = pool[machineID] else { return }
        // PowerToys invia gli appunti in linea su tutti i socket verso la macchina: lo
        // stesso contenuto arriva due volte a distanza di millisecondi.
        var hasher = Hasher()
        hasher.combine(payload.kind)
        hasher.combine(payload.data)
        let digest = hasher.finalize()
        if let last = lastReceivedDigest, last.digest == digest, Date().timeIntervalSince(last.time) < 3 { return }
        lastReceivedDigest = (digest, Date())
        log.debug("Appunti ricevuti da \(machine.name): \(payload.kind.rawValue), \(payload.data.count) byte")
        onClipboardReceived?(payload, machine)
    }

    // MARK: Manutenzione

    private func tick() {
        guard running else { return }
        connectIfNeeded()
        // Connessioni mai arrivate alla fiducia (peer muto, chiave errata senza dati…).
        for peer in peers where !peer.isTrusted && Date().timeIntervalSince(peer.createdAt) > 15 {
            peer.close(.network("handshake non completato in tempo"))
        }
        if Date().timeIntervalSince(lastHeartbeat) >= configuration.heartbeatInterval {
            sendHeartbeat()
        }
    }

    private func sendHeartbeat() {
        lastHeartbeat = Date()
        broadcast(Packet(type: .heartbeat, des: MachineID.all, machineName: configuration.localName))
    }

    // MARK: Ricezione

    private func received(_ packet: Packet, from peer: PeerConnection) {
        guard !isDuplicate(packet) else { return }
        switch packet.type {
        case .hello:
            // `Receiver.ProcessPackage`: a Hello si risponde con un heartbeat.
            sendHeartbeat()
        case .clipboard:
            // `Receiver.cs`: il mittente ha negli appunti dati troppo grandi per l'invio in
            // linea. PowerToys li ritira al cambio macchina; qui si ritirano subito, così
            // sono già pronti quando si torna al Mac.
            pullClipboard(from: packet.src)
        case .clipboardAsk:
            // Il mittente non riesce a connettersi al nostro canale appunti e chiede che
            // i dati gli vengano spinti (`Clipboard.ConnectAndGetData`).
            if packet.des == configuration.machineID { pushClipboard(to: packet.src) }
        default:
            break
        }
        onPacket?(packet)
    }

    /// PowerToys invia lo stesso pacchetto su tutti i socket verso una macchina e il
    /// ricevente scarta i doppioni con una coda degli ultimi 50 Id (`Receiver.PreProcess`).
    private func isDuplicate(_ packet: Packet) -> Bool {
        if packet.type == .clipboardText || packet.type == .clipboardImage { return false }
        if recentIDs.contains(packet.id) { return true }
        recentIndex = (recentIndex + 1) % recentIDs.count
        recentIDs[recentIndex] = packet.id
        return false
    }
}
