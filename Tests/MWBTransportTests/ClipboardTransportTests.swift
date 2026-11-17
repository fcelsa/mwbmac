import Foundation
import Network
import Testing
import MWBProtocol
@testable import MWBTransport

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [T] = []
    func add(_ value: T) { lock.lock(); values.append(value); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return values }

    func wait(count: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if all.count >= count { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return all.count >= count
    }
}

private func pseudoRandom(_ count: Int, seed: UInt64) -> [UInt8] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    }
}

/// Appunti fra due sessioni su loopback: il "PC" ascolta sui due canali, il "Mac" si connette.
@Suite(.serialized)
struct ClipboardSessionTests {
    private func makePair(port: UInt16, scheme: CipherScheme = .current) -> (pc: Session, mac: Session) {
        var pcConfiguration = Session.Configuration(localName: "pc-finto", machineID: 1111,
                                                    securityKey: "MwbEncryptionTestKey1234", remoteHost: nil,
                                                    basePort: port, listenPort: port + 1)
        pcConfiguration.cipherScheme = scheme
        pcConfiguration.clipboardListenPort = port
        let pc = Session(configuration: pcConfiguration)
        let mac = Session(configuration: .init(localName: "mac-finto", machineID: 2222,
                                               securityKey: "MwbEncryptionTestKey1234", remoteHost: "127.0.0.1",
                                               basePort: port, listenPort: nil,
                                               heartbeatInterval: 1, reconnectInterval: 0.5))
        pc.log.sink = { _ in }
        mac.log.sink = { _ in }
        return (pc, mac)
    }

    private func connect(_ pc: Session, _ mac: Session) async -> Bool {
        let connected = Box<String>()
        pc.onMachineConnected = { _ in connected.add("pc") }
        mac.onMachineConnected = { _ in connected.add("mac") }
        pc.start()
        mac.start()
        return await connected.wait(count: 2, timeout: 10)
    }

    @Test func smallClipboardTravelsInlineBothWays() async throws {
        let (pc, mac) = makePair(port: 25200)
        let atPC = Box<ClipboardPayload>()
        let atMac = Box<ClipboardPayload>()
        pc.onClipboardReceived = { payload, machine in
            #expect(machine.name == "mac-finto")
            atPC.add(payload)
        }
        mac.onClipboardReceived = { payload, _ in atMac.add(payload) }
        #expect(await connect(pc, mac))

        let text = ClipboardPayload(kind: .text, data: ClipboardText(plain: "ciao dal Mac").encoded())
        mac.sendClipboard(text)
        #expect(await atPC.wait(count: 1, timeout: 5))
        let received = try #require(atPC.all.first)
        #expect(received.kind == .text)
        #expect(try ClipboardText(decoding: received.data).plain == "ciao dal Mac")

        // Immagine da 300 KB non allineata a 48 byte: arriva riempita di zeri in coda.
        let image = ClipboardPayload(kind: .image, data: pseudoRandom(300_001, seed: 7))
        pc.sendClipboard(image)
        #expect(await atMac.wait(count: 1, timeout: 10))
        let back = try #require(atMac.all.first)
        #expect(back.kind == .image)
        #expect(Array(back.data.prefix(300_001)) == image.data)
        #expect(back.data.count - 300_001 < 48)

        // Nessuna consegna doppia.
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(atPC.all.count == 1)
        #expect(atMac.all.count == 1)
        mac.stop()
        pc.stop()
    }

    /// Dati grandi copiati sul PC: annuncio, e il Mac li ritira dal canale appunti.
    @Test func bigClipboardIsAnnouncedAndPulled() async throws {
        let (pc, mac) = makePair(port: 25210)
        let atMac = Box<ClipboardPayload>()
        mac.onClipboardReceived = { payload, machine in
            #expect(machine.id == 1111)
            atMac.add(payload)
        }
        #expect(await connect(pc, mac))

        let big = ClipboardPayload(kind: .image, data: pseudoRandom(3_000_007, seed: 11))
        #expect(!big.isInline)
        pc.sendClipboard(big)
        #expect(await atMac.wait(count: 1, timeout: 20))
        #expect(atMac.all.first == big)
        mac.stop()
        pc.stop()
    }

    /// Dati grandi copiati sul Mac e richiesti dal PC con `ClipboardAsk`: il Mac li spinge.
    @Test func bigClipboardIsPushedOnAsk() async throws {
        let (pc, mac) = makePair(port: 25220)
        let atPC = Box<ClipboardPayload>()
        let announced = Box<Packet>()
        pc.onClipboardReceived = { payload, _ in atPC.add(payload) }
        pc.onPacket = { if $0.type == .clipboard { announced.add($0) } }
        #expect(await connect(pc, mac))

        let big = ClipboardPayload(kind: .text, data: pseudoRandom(1_500_000, seed: 3))
        mac.sendClipboard(big)
        // Il "PC" riceve l'annuncio; qui la sua richiesta automatica fallirebbe (stesso
        // host, stessa porta), quindi si usa la via di `ClipboardAsk` come farebbe PowerToys
        // quando non riesce a connettersi al Mac.
        #expect(await announced.wait(count: 1, timeout: 5))
        #expect(announced.all.first?.machineName == "mac-finto")
        pc.send(Packet(type: .clipboardAsk, des: 2222, machineName: "pc-finto"))
        #expect(await atPC.wait(count: 1, timeout: 20))
        #expect(atPC.all.first == big)
        mac.stop()
        pc.stop()
    }

    @Test func legacySchemeAlsoCarriesTheClipboardChannel() async throws {
        let (pc, mac) = makePair(port: 25230, scheme: .legacy)
        let atMac = Box<ClipboardPayload>()
        mac.onClipboardReceived = { payload, _ in atMac.add(payload) }
        #expect(await connect(pc, mac))
        let big = ClipboardPayload(kind: .image, data: pseudoRandom(1_200_000, seed: 5))
        pc.sendClipboard(big)
        #expect(await atMac.wait(count: 1, timeout: 20))
        #expect(atMac.all.first == big)
        mac.stop()
        pc.stop()
    }
}

/// Il canale appunti preso da solo, nei ruoli che servono contro PowerToys.
@Suite(.serialized)
struct ClipboardTransferTests {
    private let queue = DispatchQueue(label: "test.clipboard")

    private func context(name: String, id: UInt32, key: String = "MwbEncryptionTestKey1234") -> PeerConnection.Context {
        let log = Log()
        log.sink = { _ in }
        return PeerConnection.Context(securityKey: key, magic: KeyDerivation.magicNumber(securityKey: key),
                                      localName: name, localID: id, scheme: .current,
                                      legacyKey: (try? KeyDerivation.legacyKey(securityKey: key)) ?? [], log: log)
    }

    private func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: nil, tcp: tcp)
    }

    /// Avvia un lato in ascolto con `serverRole` e un lato che si connette con `clientRole`.
    private func run(port: UInt16, serverRole: ClipboardTransfer.Role, clientRole: ClipboardTransfer.Role,
                     clientKey: String = "MwbEncryptionTestKey1234", knownToServer: Bool = true)
        async throws -> (server: [ClipboardTransfer.Outcome], client: [ClipboardTransfer.Outcome]) {
        let serverOutcomes = Box<ClipboardTransfer.Outcome>()
        let clientOutcomes = Box<ClipboardTransfer.Outcome>()
        let keep = Box<ClipboardTransfer>()
        let listener = try NWListener(using: parameters(), on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            let transfer = ClipboardTransfer(connection: connection, role: serverRole, scheme: .current,
                                             context: self.context(name: "mac-finto", id: 2222), queue: self.queue,
                                             isKnownMachine: { id, name in knownToServer && id == 1111 && name == "pc-finto" },
                                             completion: { _, outcome in serverOutcomes.add(outcome) })
            keep.add(transfer)
            transfer.start()
        }
        listener.start(queue: queue)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters())
        let client = ClipboardTransfer(connection: connection, role: clientRole, scheme: .current,
                                       context: context(name: "pc-finto", id: 1111, key: clientKey), queue: queue,
                                       isKnownMachine: { id, _ in id == 2222 },
                                       completion: { _, outcome in clientOutcomes.add(outcome) })
        queue.async { client.start() }
        _ = await clientOutcomes.wait(count: 1, timeout: 20)
        _ = await serverOutcomes.wait(count: 1, timeout: 15)
        listener.cancel()
        return (serverOutcomes.all, clientOutcomes.all)
    }

    /// Il caso che conta per "copia sul Mac, incolla sul PC": PowerToys si connette al
    /// Mac, saluta con `Clipboard` e legge fino alla chiusura della connessione.
    @Test func peerPullsFromOurListener() async throws {
        for (index, size) in [1, 15, 16, 1_048_577, 4_000_003].enumerated() {
            let payload = ClipboardPayload(kind: .image, data: pseudoRandom(size, seed: UInt64(size)))
            let result = try await run(port: 25300 + UInt16(index), serverRole: .serve(payload), clientRole: .pull)
            guard case .received(let received, let machineID, let name)? = result.client.first else {
                Issue.record("dimensione \(size): \(result.client)")
                continue
            }
            #expect(received == payload, "dimensione \(size)")
            #expect(machineID == 2222)
            #expect(name == "mac-finto")
            guard case .sent(let to, let bytes)? = result.server.first else {
                Issue.record("lato che invia, dimensione \(size): \(result.server)")
                continue
            }
            #expect(to == 1111)
            #expect(bytes == size)
        }
    }

    /// `Clipboard.ShakeHand` confronta l'intero campo tipo a 32 bit: nel saluto i byte di
    /// checksum e magic devono essere zero, o PowerToys scarta la connessione.
    @Test func greetingHasNoChecksumOrMagic() {
        for type in [PackageType.clipboard, .clipboardPush] {
            let bytes = ClipboardTransfer.greeting(type: type, localName: "office-macbook1", localID: 0x11223344)
            #expect(bytes.count == 64)
            #expect(Array(bytes[0..<4]) == [type.rawValue, 0, 0, 0])
            #expect(Array(bytes[8..<12]) == [0x44, 0x33, 0x22, 0x11])
            #expect(String(decoding: bytes[32..<64], as: UTF8.self) == "office-macbook1" + String(repeating: " ", count: 17))
        }
    }

    /// PowerToys non si ferma alla dimensione dichiarata: legge finché la connessione non
    /// viene chiusa. Qui un lettore grezzo fa lo stesso e verifica che la fine del flusso
    /// arrivi subito dopo i dati, in un multiplo di 16 byte.
    @Test func senderClosesTheStreamAfterTheData() async throws {
        let payload = ClipboardPayload(kind: .image, data: pseudoRandom(1_300_335, seed: 21))
        let port: UInt16 = 25320
        let keep = Box<ClipboardTransfer>()
        let serverOutcome = Box<ClipboardTransfer.Outcome>()
        let listener = try NWListener(using: parameters(), on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            let transfer = ClipboardTransfer(connection: connection, role: .serve(payload), scheme: .current,
                                             context: self.context(name: "mac-finto", id: 2222), queue: self.queue,
                                             isKnownMachine: { _, _ in true }, completion: { _, outcome in serverOutcome.add(outcome) })
            keep.add(transfer)
            transfer.start()
        }
        listener.start(queue: queue)

        // Lato "PowerToys": intestazione, blocco casuale e saluto `Clipboard`, poi sola lettura.
        let peer = context(name: "pc-finto", id: 1111)
        let header = KeyDerivation.randomBytes(KeyDerivation.headerSize)
        let key = try KeyDerivation.deriveKey(securityKey: peer.securityKey, salt: Array(header[0..<16]))
        let encryptor = try CipherStream(key: key, iv: Array(header[16...]), direction: .encrypt)
        var greeting = Packet(type: .clipboard, machineName: "pc-finto")
        greeting.src = 1111
        _ = greeting
        let hello = try encryptor.process(KeyDerivation.randomBytes(16)
            + ClipboardTransfer.greeting(type: .clipboard, localName: "pc-finto", localID: 1111))

        let received = Box<Int>()
        let ended = Box<Date>()
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters())
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let data { received.add(data.count) }
                if isComplete || error != nil { ended.add(Date()) } else { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(header + hello), completion: .contentProcessed { _ in })
                read()
            }
        }
        let started = Date()
        connection.start(queue: queue)
        #expect(await ended.wait(count: 1, timeout: 8), "la fine del flusso non è arrivata")
        let total = received.all.reduce(0, +)
        // 32 di intestazione in chiaro + 16 casuali + 64 di saluto + 1024 + dati allineati a 16.
        let expected = 32 + 16 + 64 + 1024 + (payload.data.count + 15) / 16 * 16
        #expect(total == expected)
        #expect((total - 32) % 16 == 0)
        if let end = ended.all.first { #expect(end.timeIntervalSince(started) < 5) }
        // Il gestore cattura la connessione: va tolto, o connessione e gestore si
        // trattengono a vicenda (lo segnala `leaks`).
        connection.stateUpdateHandler = nil
        connection.cancel()
        listener.cancel()
        // Anche il lato che invia deve concludere (e liberare la connessione).
        #expect(await serverOutcome.wait(count: 1, timeout: 5), "il trasferimento lato Mac non si è concluso")
        if case .sent(_, let bytes)? = serverOutcome.all.first { #expect(bytes == payload.data.count) }
        else { Issue.record("esito lato Mac: \(serverOutcome.all)") }
    }

    @Test func peerPushesToOurListener() async throws {
        let payload = ClipboardPayload(kind: .text, data: pseudoRandom(2_000_001, seed: 9))
        let result = try await run(port: 25310, serverRole: .serve(nil), clientRole: .push(payload))
        guard case .received(let received, let machineID, _)? = result.server.first else {
            Issue.record("\(result.server)")
            return
        }
        #expect(received == payload)
        #expect(machineID == 1111)
    }

    @Test func nothingToOfferFailsCleanly() async throws {
        let result = try await run(port: 25311, serverRole: .serve(nil), clientRole: .pull)
        guard case .failed? = result.server.first, case .failed? = result.client.first else {
            Issue.record("\(result)")
            return
        }
    }

    @Test func unknownMachineAndWrongKeyAreRejected() async throws {
        let payload = ClipboardPayload(kind: .text, data: [1, 2, 3, 4])
        let unknown = try await run(port: 25312, serverRole: .serve(payload), clientRole: .pull, knownToServer: false)
        guard case .failed? = unknown.server.first, case .failed? = unknown.client.first else {
            Issue.record("macchina sconosciuta: \(unknown)")
            return
        }
        let wrongKey = try await run(port: 25313, serverRole: .serve(payload), clientRole: .pull,
                                     clientKey: "UnaChiaveDiversa12345")
        guard case .failed? = wrongKey.server.first, case .failed? = wrongKey.client.first else {
            Issue.record("chiave errata: \(wrongKey)")
            return
        }
    }
}
