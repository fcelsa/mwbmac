// Una connessione del canale appunti (porta base di MWB).
// Fonte: PowerToys `Clipboard.ShakeHand`, `ReceiveAndProcessClipboardDataCore`,
// `SocketStuff.SendClipboardData`.
//
// Stessa cifratura del canale messaggi (intestazione salt+IV, blocco casuale). Poi ogni
// lato invia un pacchetto di saluto da 64 byte, senza magic né checksum: tipo `Clipboard`
// se vuole ricevere, `ClipboardPush` se sta per inviare, con MachineId e nome. Chi invia
// prosegue con 1024 byte di intestazione ("<dimensione>*<text|image>") e i dati; chi
// riceve legge fino alla chiusura della connessione.
// Tutti i metodi vanno chiamati sulla coda seriale della sessione.

import Foundation
import MWBProtocol
import Network

final class ClipboardTransfer {
    enum Role {
        /// Connessione uscente: chiediamo i dati al peer.
        case pull
        /// Connessione uscente: inviamo i nostri dati (risposta a `ClipboardAsk`).
        case push(ClipboardPayload)
        /// Connessione entrante: decide il saluto del peer. `payload` è ciò che abbiamo da offrire.
        case serve(ClipboardPayload?)
    }

    enum Outcome {
        case received(ClipboardPayload, machineID: UInt32, machineName: String)
        case sent(machineID: UInt32, bytes: Int)
        case failed(String)
    }

    private enum Phase {
        case greeting
        case header
        case body(kind: ClipboardKind, size: Int)
        case sending
        case done
    }

    private let connection: NWConnection
    private let role: Role
    private let context: PeerConnection.Context
    private let scheme: CipherScheme
    private let queue: DispatchQueue
    /// Verifica che il peer sia una macchina con cui c'è una connessione fidata.
    private let isKnownMachine: (UInt32, String) -> Bool
    private let completion: (ClipboardTransfer, Outcome) -> Void
    let label: String

    private var encryptor: CipherStream?
    private var decryptor: CipherStream?
    private var cipherBuffer: [UInt8] = []
    private var plainBuffer: [UInt8] = []
    private var randomBlockSkipped = false
    private var phase = Phase.greeting
    private var body: [UInt8] = []
    private var peerID: UInt32 = MachineID.none
    private var peerName = ""
    private var finished = false
    private var lastActivity = Date()
    private var watchdog: DispatchSourceTimer?

    /// Senza traffico per questo tempo il trasferimento viene abbandonato.
    static let inactivityTimeout: TimeInterval = 30

    init(connection: NWConnection, role: Role, scheme: CipherScheme, context: PeerConnection.Context,
         queue: DispatchQueue, isKnownMachine: @escaping (UInt32, String) -> Bool,
         completion: @escaping (ClipboardTransfer, Outcome) -> Void) {
        self.connection = connection
        self.role = role
        self.scheme = scheme == .legacy ? .legacy : .current
        self.context = context
        self.queue = queue
        self.isKnownMachine = isKnownMachine
        self.completion = completion
        self.label = "clipboard \(connection.endpoint)"
    }

    /// Il gestore di stato di `NWConnection` trattiene la connessione stessa: se il
    /// trasferimento viene abbandonato senza concluderlo, il ciclo va spezzato qui.
    deinit {
        watchdog?.cancel()
        if !finished {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.didBecomeReady()
            case .failed(let error): self.finish(.failed("network error: \(error)"))
            case .waiting(let error): self.finish(.failed("connection failed: \(error)"))
            case .cancelled: self.finish(.failed("annullata"))
            default: break
            }
        }
        connection.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            if Date().timeIntervalSince(self.lastActivity) > ClipboardTransfer.inactivityTimeout {
                self.finish(.failed("no activity for \(Int(ClipboardTransfer.inactivityTimeout)) s"))
            }
        }
        timer.resume()
        watchdog = timer
    }

    func cancel() {
        finish(.failed("annullata"))
    }

    // MARK: Apertura e saluto

    private func didBecomeReady() {
        guard encryptor == nil, !finished else { return }
        do {
            let stream: CipherStream
            if scheme == .legacy {
                stream = try CipherStream(key: context.legacyKey, iv: KeyDerivation.legacyIV, direction: .encrypt)
            } else {
                let header = KeyDerivation.randomBytes(KeyDerivation.headerSize)
                let key = try KeyDerivation.deriveKey(securityKey: context.securityKey,
                                                      salt: Array(header[0..<KeyDerivation.saltSize]))
                stream = try CipherStream(key: key, iv: Array(header[KeyDerivation.saltSize...]), direction: .encrypt)
                sendRaw(header)
            }
            encryptor = stream
            // Saluto: `Clipboard` = "voglio ricevere", `ClipboardPush` = "sto per inviare".
            // Il lato in ascolto di PowerToys saluta sempre con `ClipboardPush`.
            let type: PackageType
            switch role {
            case .pull: type = .clipboard
            case .push, .serve: type = .clipboardPush
            }
            let greeting = ClipboardTransfer.greeting(type: type, localName: context.localName, localID: context.localID)
            try sendEncrypted(KeyDerivation.randomBytes(KeyDerivation.blockSize) + greeting)
        } catch {
            finish(.failed("inizializzazione della cifratura fallita: \(error)"))
            return
        }
        receive()
    }

    /// Pacchetto di saluto. A differenza del canale messaggi qui PowerToys non azzera
    /// checksum e magic prima di leggere il tipo: `ShakeHand` confronta l'intero campo a
    /// 32 bit con `Clipboard`/`ClipboardPush`, quindi i byte 1..3 devono essere zero,
    /// altrimenti la connessione viene scartata (e lasciata aperta, senza errori).
    static func greeting(type: PackageType, localName: String, localID: UInt32) -> [UInt8] {
        var packet = Packet(type: type, machineName: localName)
        packet.src = localID
        var bytes = packet.serialized(magic: 0)
        bytes[1] = 0
        return bytes
    }

    private func handleGreeting(_ bytes: [UInt8]) {
        // Il saluto non porta magic né checksum: si leggono i campi direttamente.
        let type = PackageType(rawValue: bytes[0])
        peerID = UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24
        peerName = String(decoding: bytes[32..<64], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
        guard type == .clipboard || type == .clipboardPush else {
            // Con la chiave sbagliata il saluto è rumore.
            finish(.failed("invalid greeting (type \(bytes[0]))"))
            return
        }
        guard isKnownMachine(peerID, peerName) else {
            finish(.failed("\"\(peerName)\" (id \(peerID)) is not a connected machine"))
            return
        }
        switch role {
        case .pull:
            phase = .header
        case .push(let payload):
            send(payload)
        case .serve(let payload):
            if type == .clipboardPush {
                phase = .header
            } else if let payload {
                send(payload)
            } else {
                finish(.failed("\"\(peerName)\" asks for the clipboard but there is nothing to send"))
            }
        }
    }

    // MARK: Invio

    private func send(_ payload: ClipboardPayload) {
        phase = .sending
        // I dati vanno allineati al blocco AES: PowerToys scarta ciò che eccede la
        // dimensione dichiarata, ma un blocco incompleto in coda farebbe fallire la lettura.
        var plain = payload.transferHeader() + payload.data
        let remainder = plain.count % KeyDerivation.blockSize
        if remainder != 0 { plain.append(contentsOf: [UInt8](repeating: 0, count: KeyDerivation.blockSize - remainder)) }
        do {
            guard let encryptor else { throw CryptoError.invalidParameter }
            let cipher = try encryptor.process(plain)
            let total = payload.data.count
            // PowerToys legge fino alla chiusura: l'invio termina il flusso (FIN).
            connection.send(content: Data(cipher), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(.failed("invio fallito: \(error)"))
                } else {
                    self.lastActivity = Date()
                    self.pendingSent = total
                    // Si aspetta che il peer chiuda dopo aver letto tutto; `receive()` è già attivo.
                    self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.completeSend() }
                }
            })
        } catch {
            finish(.failed("cifratura fallita: \(error)"))
        }
    }

    private var pendingSent: Int?

    private func completeSend() {
        guard let pendingSent else { return }
        finish(.sent(machineID: peerID, bytes: pendingSent))
    }

    private func sendRaw(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failed("invio fallito: \(error)")) }
        })
    }

    private func sendEncrypted(_ plain: [UInt8]) throws {
        guard let encryptor else { throw CryptoError.invalidParameter }
        sendRaw(try encryptor.process(plain))
    }

    // MARK: Ricezione

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                self.cipherBuffer.append(contentsOf: data)
                self.drain()
            }
            if self.finished { return }
            if error != nil || isComplete {
                self.peerClosed()
            } else {
                self.receive()
            }
        }
    }

    private func drain() {
        do {
            if decryptor == nil {
                if scheme == .legacy {
                    decryptor = try CipherStream(key: context.legacyKey, iv: KeyDerivation.legacyIV, direction: .decrypt)
                } else {
                    guard cipherBuffer.count >= KeyDerivation.headerSize else { return }
                    let key = try KeyDerivation.deriveKey(securityKey: context.securityKey,
                                                          salt: Array(cipherBuffer[0..<KeyDerivation.saltSize]))
                    let iv = Array(cipherBuffer[KeyDerivation.saltSize..<KeyDerivation.headerSize])
                    decryptor = try CipherStream(key: key, iv: iv, direction: .decrypt)
                    cipherBuffer.removeFirst(KeyDerivation.headerSize)
                }
            }
            if !cipherBuffer.isEmpty, let decryptor {
                plainBuffer.append(contentsOf: try decryptor.process(cipherBuffer))
                cipherBuffer.removeAll(keepingCapacity: true)
            }
        } catch {
            finish(.failed("decifratura fallita: \(error)"))
            return
        }

        if !randomBlockSkipped {
            guard plainBuffer.count >= KeyDerivation.blockSize else { return }
            plainBuffer.removeFirst(KeyDerivation.blockSize)
            randomBlockSkipped = true
        }

        while !finished {
            switch phase {
            case .greeting:
                guard plainBuffer.count >= Packet.sizeEx else { return }
                let bytes = Array(plainBuffer[0..<Packet.sizeEx])
                plainBuffer.removeFirst(Packet.sizeEx)
                handleGreeting(bytes)
            case .header:
                guard plainBuffer.count >= ClipboardPayload.transferHeaderSize else { return }
                let header = Array(plainBuffer[0..<ClipboardPayload.transferHeaderSize])
                plainBuffer.removeFirst(ClipboardPayload.transferHeaderSize)
                guard let parsed = ClipboardPayload.parseTransferHeader(header) else {
                    finish(.failed("invalid data header"))
                    return
                }
                guard let kind = ClipboardPayload.kind(forTransferName: parsed.name) else {
                    // File o cartella: fuori perimetro, si chiude prima di riceverlo.
                    finish(.failed("\"\(peerName)\" offers a file, not supported: \(parsed.name)"))
                    return
                }
                guard parsed.size > 0, parsed.size <= ClipboardPayload.maxSize else {
                    finish(.failed("unacceptable size: \(parsed.size) bytes"))
                    return
                }
                body.reserveCapacity(parsed.size)
                phase = .body(kind: kind, size: parsed.size)
            case .body(let kind, let size):
                guard !plainBuffer.isEmpty else { return }
                body.append(contentsOf: plainBuffer.prefix(size - body.count))
                plainBuffer.removeAll(keepingCapacity: true)
                guard body.count >= size else { return }
                deliver(kind: kind)
                return
            case .sending, .done:
                // Chi riceve i nostri dati non ha altro da dirci.
                plainBuffer.removeAll()
                return
            }
        }
    }

    private func peerClosed() {
        switch phase {
        case .body(let kind, let size):
            // PowerToys può perdere gli ultimi byte (blocco AES incompleto mai inviato):
            // se manca poco si consegna comunque, la decodifica a valle sa ripararlo.
            if size - body.count < KeyDerivation.blockSize, !body.isEmpty {
                context.log.debug("\(label): received \(body.count) of \(size) bytes, delivering anyway")
                deliver(kind: kind)
            } else {
                finish(.failed("trasferimento interrotto a \(body.count) byte su \(size)"))
            }
        case .sending:
            if pendingSent != nil { completeSend() } else { finish(.failed("closed by the peer while sending")) }
        default:
            finish(.failed("closed by the peer"))
        }
    }

    private func deliver(kind: ClipboardKind) {
        let payload = ClipboardPayload(kind: kind, data: body)
        body = []
        finish(.received(payload, machineID: peerID, machineName: peerName))
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        phase = .done
        watchdog?.cancel()
        watchdog = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(self, outcome)
    }
}
