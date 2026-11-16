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
    private var reportedInvalidKey = false

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
        guard running, let host = configuration.remoteHost, !host.isEmpty else { return }
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
        reportedInvalidKey = false
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
        if case .invalidKey = reason, !reportedInvalidKey {
            reportedInvalidKey = true
            log.info("\(peer.label): \(reason)")
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
        case .byeBye:
            // La chiusura dei socket segue a ruota; qui si avvisa subito chi controlla.
            break
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
