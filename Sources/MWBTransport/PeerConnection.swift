// Una connessione TCP cifrata verso (o da) un'altra macchina MWB.
// Fonte: PowerToys `SocketStuff.MainTCPRoutine`, `TcpSk`, `TcpReceiveData`.
//
// Due schemi di cifratura, secondo la versione di PowerToys installata sul PC:
//   - corrente: 32 byte in chiaro (salt + IV) all'inizio di ogni direzione, chiave
//     PBKDF2 a 100000 iterazioni su quel salt;
//   - storico: nessuna intestazione, salt e IV fissi, 50000 iterazioni.
// In entrambi il primo blocco cifrato è casuale e va scartato; seguono 10 pacchetti
// Handshake e poi il traffico. PowerToys trasmette per primo appena la connessione è
// aperta, quindi in modalità automatica si aspetta il suo flusso, si riconosce lo
// schema e solo allora si risponde: così al PC non arriva mai un flusso illeggibile.
// Tutti i metodi vanno chiamati sulla coda seriale della sessione.

import Foundation
import MWBProtocol
import Network

/// Schema di cifratura del flusso.
public enum CipherScheme: String, Sendable {
    /// Riconosce lo schema dal flusso del peer.
    case auto
    /// Intestazione salt+IV per connessione (PowerToys recenti).
    case current
    /// Salt e IV fissi (PowerToys meno recenti).
    case legacy
}

final class PeerConnection {
    struct Context {
        let securityKey: String
        let magic: UInt32
        let localName: String
        let localID: UInt32
        let scheme: CipherScheme
        let legacyKey: [UInt8]
        let log: Log
    }

    enum CloseReason: CustomStringConvertible {
        case network(String)
        case invalidKey
        case local

        var description: String {
            switch self {
            case .network(let detail): return detail
            case .invalidKey: return "flusso illeggibile: la security key non coincide con quella del PC"
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
    /// Schema effettivamente in uso, noto dopo il riconoscimento.
    private(set) var activeScheme: CipherScheme?
    let createdAt = Date()

    /// Byte del peer necessari a riconoscere lo schema: intestazione (32) + blocco
    /// casuale (16) + primi 32 byte di un pacchetto.
    static let detectionSize = KeyDerivation.headerSize + KeyDerivation.blockSize + Packet.size
    /// Se il peer resta muto (non è PowerToys) si parte con lo schema corrente.
    static let detectionTimeout: TimeInterval = 1.5

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
        if context.scheme == .auto {
            queue.asyncAfter(deadline: .now() + PeerConnection.detectionTimeout) { [weak self] in
                guard let self, !self.isClosed, self.activeScheme == nil else { return }
                self.context.log.debug("\(self.label): il peer non trasmette, parto con lo schema corrente")
                self.adopt(scheme: .current)
            }
        } else {
            adopt(scheme: context.scheme)
        }
        receive()
    }

    /// Fissa lo schema e apre la nostra direzione: (intestazione), blocco casuale, sfida.
    private func adopt(scheme: CipherScheme) {
        guard activeScheme == nil, !isClosed else { return }
        activeScheme = scheme
        context.log.debug("\(label): schema di cifratura \(scheme.rawValue)")
        do {
            let stream: CipherStream
            if scheme == .legacy {
                stream = try CipherStream(key: context.legacyKey, iv: KeyDerivation.legacyIV, direction: .encrypt)
            } else {
                // Intestazione in chiaro: salt e IV freschi per questa direzione.
                let header = KeyDerivation.randomBytes(KeyDerivation.headerSize)
                let key = try KeyDerivation.deriveKey(securityKey: context.securityKey,
                                                      salt: Array(header[0..<KeyDerivation.saltSize]))
                stream = try CipherStream(key: key, iv: Array(header[KeyDerivation.saltSize...]), direction: .encrypt)
                sendRaw(header)
            }
            encryptor = stream
            sendRaw(try stream.process(KeyDerivation.randomBytes(KeyDerivation.blockSize)))
            for _ in 0..<Handshake.repeatCount { send(challenge) }
        } catch {
            close(.network("inizializzazione della cifratura fallita: \(error)"))
        }
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

    /// Riconosce lo schema dai primi byte del peer: quello giusto è l'unico che, tolto
    /// il blocco casuale, produce un pacchetto con magic e checksum validi.
    private func detectScheme() throws -> CipherScheme? {
        let legacy = try CipherStream(key: context.legacyKey, iv: KeyDerivation.legacyIV, direction: .decrypt)
        let legacyPlain = try legacy.process(Array(cipherBuffer[0..<(KeyDerivation.blockSize + Packet.size)]))
        if (try? Packet.validate(header: Array(legacyPlain[KeyDerivation.blockSize...]), magic: context.magic)) != nil {
            return .legacy
        }
        let key = try KeyDerivation.deriveKey(securityKey: context.securityKey,
                                              salt: Array(cipherBuffer[0..<KeyDerivation.saltSize]))
        let iv = Array(cipherBuffer[KeyDerivation.saltSize..<KeyDerivation.headerSize])
        let current = try CipherStream(key: key, iv: iv, direction: .decrypt)
        let currentPlain = try current.process(Array(cipherBuffer[KeyDerivation.headerSize..<PeerConnection.detectionSize]))
        if (try? Packet.validate(header: Array(currentPlain[KeyDerivation.blockSize...]), magic: context.magic)) != nil {
            return .current
        }
        // Diagnosi: con la decifratura giusta e il solo magic sbagliato il tipo sarebbe 126.
        let expected = [UInt8((context.magic >> 16) & 0xFF), UInt8((context.magic >> 24) & 0xFF)]
        func summary(_ plain: [UInt8]) -> String {
            let p = Array(plain[KeyDerivation.blockSize...])
            return "tipo=\(p[0]) magic=\(p[2]),\(p[3]) (atteso \(expected[0]),\(expected[1]))"
        }
        context.log.debug("\(label): ricevuti \(cipherBuffer.count) byte; storico: \(summary(legacyPlain)); corrente: \(summary(currentPlain))")
        return nil
    }

    private func drain() {
        do {
            if decryptor == nil {
                var scheme = activeScheme
                if scheme == nil {
                    guard cipherBuffer.count >= PeerConnection.detectionSize else { return }
                    guard let detected = try detectScheme() else {
                        // Niente è stato inviato al peer: chiusura pulita, senza rumore.
                        close(.invalidKey)
                        return
                    }
                    adopt(scheme: detected)
                    scheme = detected
                }
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
