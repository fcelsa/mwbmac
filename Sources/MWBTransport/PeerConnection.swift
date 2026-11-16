// Una connessione TCP cifrata verso (o da) un'altra macchina MWB.
// Fonte: PowerToys `SocketStuff.MainTCPRoutine`, `TcpSk`, `TcpReceiveData`.
//
// Sequenza per ciascuna direzione: 32 byte in chiaro (salt + IV), poi flusso AES con
// un primo blocco casuale da scartare, 10 pacchetti Handshake, quindi il traffico.
// Tutti i metodi vanno chiamati sulla coda seriale della sessione.

import Foundation
import MWBProtocol
import Network

final class PeerConnection {
    struct Context {
        let securityKey: String
        let magic: UInt32
        let localName: String
        let localID: UInt32
        let log: Log
    }

    enum CloseReason: CustomStringConvertible {
        case network(String)
        case invalidKey
        case local

        var description: String {
            switch self {
            case .network(let detail): return detail
            case .invalidKey: return "pacchetti non validi: la security key non coincide con quella del PC?"
            case .local: return "chiusa localmente"
            }
        }
    }

    let connection: NWConnection
    let isOutgoing: Bool
    let label: String
    private let context: Context
    private let queue: DispatchQueue

    var onTrusted: ((PeerConnection) -> Void)?
    var onPacket: ((Packet, PeerConnection) -> Void)?
    var onClosed: ((PeerConnection, CloseReason) -> Void)?

    private(set) var remoteID: UInt32 = MachineID.none
    private(set) var remoteName: String = ""
    private(set) var isTrusted = false
    private(set) var isClosed = false
    private(set) var isReady = false
    let createdAt = Date()

    private var encryptor: CipherStream?
    private var decryptor: CipherStream?
    private var cipherBuffer: [UInt8] = []
    private var plainBuffer: [UInt8] = []
    private var randomBlockSkipped = false
    private var challenge: Packet
    private var invalidCount = 0

    init(connection: NWConnection, isOutgoing: Bool, context: Context, queue: DispatchQueue) {
        self.connection = connection
        self.isOutgoing = isOutgoing
        self.context = context
        self.queue = queue
        self.label = "\(isOutgoing ? "→" : "←") \(connection.endpoint)"
        self.challenge = Handshake.challenge(localName: context.localName, localID: context.localID)
        // Come PowerToys, la sfida ha un Id casuale: non passa dal contatore della sessione.
        self.challenge.id = Int32.random(in: 1...Int32.max)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.didBecomeReady()
            case .failed(let error):
                self.close(.network("errore di rete: \(error)"))
            case .waiting(let error):
                // Host irraggiungibile o porta chiusa: ci pensa la sessione a riprovare.
                self.close(.network("in attesa: \(error)"))
            case .cancelled:
                self.close(.local)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func close(_ reason: CloseReason) {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(self, reason)
    }

    /// Invia un pacchetto già completo di Id, Src e Des.
    func send(_ packet: Packet) {
        guard !isClosed, let encryptor else { return }
        if context.log.protocolEnabled { context.log.packet("TX", label, packet) }
        do {
            let cipher = try encryptor.process(packet.serialized(magic: context.magic))
            sendRaw(cipher)
        } catch {
            close(.network("cifratura fallita: \(error)"))
        }
    }

    // MARK: Apertura

    private func didBecomeReady() {
        guard !isReady, !isClosed else { return }
        isReady = true
        do {
            // Intestazione in chiaro: salt e IV freschi per questa direzione.
            let header = KeyDerivation.randomBytes(KeyDerivation.headerSize)
            let key = try KeyDerivation.deriveKey(securityKey: context.securityKey,
                                                  salt: Array(header[0..<KeyDerivation.saltSize]))
            let stream = try CipherStream(key: key, iv: Array(header[KeyDerivation.saltSize...]), direction: .encrypt)
            encryptor = stream
            sendRaw(header)
            sendRaw(try stream.process(KeyDerivation.randomBytes(KeyDerivation.blockSize)))
            for _ in 0..<Handshake.repeatCount { send(challenge) }
        } catch {
            close(.network("inizializzazione della cifratura fallita: \(error)"))
            return
        }
        receive()
    }

    private func sendRaw(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.close(.network("invio fallito: \(error)")) }
        })
    }

    // MARK: Ricezione

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                self.cipherBuffer.append(contentsOf: data)
                self.drain()
            }
            if let error {
                self.close(.network("ricezione fallita: \(error)"))
            } else if isComplete {
                self.close(.network("chiusa dal peer"))
            } else if !self.isClosed {
                self.receive()
            }
        }
    }

    private func drain() {
        do {
            if decryptor == nil {
                guard cipherBuffer.count >= KeyDerivation.headerSize else { return }
                let key = try KeyDerivation.deriveKey(securityKey: context.securityKey,
                                                      salt: Array(cipherBuffer[0..<KeyDerivation.saltSize]))
                let iv = Array(cipherBuffer[KeyDerivation.saltSize..<KeyDerivation.headerSize])
                decryptor = try CipherStream(key: key, iv: iv, direction: .decrypt)
                cipherBuffer.removeFirst(KeyDerivation.headerSize)
            }
            if !cipherBuffer.isEmpty, let decryptor {
                plainBuffer.append(contentsOf: try decryptor.process(cipherBuffer))
                cipherBuffer.removeAll(keepingCapacity: true)
            }
        } catch {
            close(.network("decifratura fallita: \(error)"))
            return
        }

        if !randomBlockSkipped {
            guard plainBuffer.count >= KeyDerivation.blockSize else { return }
            plainBuffer.removeFirst(KeyDerivation.blockSize)
            randomBlockSkipped = true
        }

        while !isClosed, plainBuffer.count >= Packet.size {
            let header = Array(plainBuffer[0..<Packet.size])
            let size = Packet.expectedSize(header: header, magic: context.magic)
            guard plainBuffer.count >= size else { return }
            let bytes = Array(plainBuffer[0..<size])
            plainBuffer.removeFirst(size)
            do {
                let packet = try Packet(bytes: bytes, magic: context.magic)
                invalidCount = 0
                handle(packet)
            } catch {
                invalidCount += 1
                context.log.debug("\(label): pacchetto non valido (\(error))")
                // Con la chiave sbagliata tutto il flusso è rumore: inutile insistere.
                if invalidCount > 5 { close(.invalidKey) }
            }
        }
    }

    private func handle(_ packet: Packet) {
        if context.log.protocolEnabled { context.log.packet("RX", label, packet) }
        switch packet.type {
        case .handshake:
            send(Handshake.ack(for: packet, localName: context.localName, localID: context.localID))
        case .handshakeAck:
            guard !isTrusted else { return } // gli altri nove Ack della stessa sfida
            guard Handshake.isValid(ack: packet, for: challenge) else {
                context.log.debug("\(label): Ack non valido")
                close(.invalidKey)
                return
            }
            remoteID = packet.src
            remoteName = packet.machineName
            isTrusted = true
            onTrusted?(self)
        default:
            // Prima della fiducia PowerToys conta i pacchetti inattesi; qui si ignorano.
            guard isTrusted else { return }
            onPacket?(packet, self)
        }
    }
}
