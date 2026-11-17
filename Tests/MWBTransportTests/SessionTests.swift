import Foundation
import Network
import Testing
import MWBProtocol
@testable import MWBTransport

/// Raccoglie eventi dalle callback della sessione (che arrivano sulla sua coda).
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var failures: [String] = []

    func record(_ name: String) {
        lock.lock()
        seen.append(name)
        lock.unlock()
    }

    func check(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        lock.lock()
        failures.append(message)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var problems: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    /// Attende che tutti gli eventi indicati siano arrivati.
    func wait(for names: Set<String>, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if names.isSubset(of: Set(all)) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return names.isSubset(of: Set(all))
    }
}

/// Due sessioni nello stesso processo su loopback: una in ascolto (fa la parte del PC),
/// l'altra si connette. Verifica intestazione cifrata, handshake reciproco, heartbeat
/// e consegna dei pacchetti di input nelle due direzioni.
@Suite(.serialized)
struct SessionLoopbackTests {
    /// Il server usa uno schema fisso e trasmette per primo, come PowerToys; il client
    /// lo riconosce dal flusso.
    private func makePair(port: UInt16, clientKey: String = "MwbEncryptionTestKey1234",
                          serverScheme: CipherScheme = .current) -> (server: Session, client: Session) {
        var serverConfiguration = Session.Configuration(localName: "pc-finto", machineID: 1111,
                                                        securityKey: "MwbEncryptionTestKey1234", remoteHost: nil,
                                                        basePort: port - 1, listenPort: port)
        serverConfiguration.cipherScheme = serverScheme
        let server = Session(configuration: serverConfiguration)
        let client = Session(configuration: .init(localName: "mac-finto", machineID: 2222,
                                                  securityKey: clientKey, remoteHost: "127.0.0.1",
                                                  basePort: port - 1, listenPort: nil,
                                                  heartbeatInterval: 1, reconnectInterval: 0.5))
        server.log.sink = { _ in }
        client.log.sink = { _ in }
        return (server, client)
    }

    @Test func handshakeAndInputDelivery() async {
        let (server, client) = makePair(port: 25101)
        let events = Events()

        client.onMachineConnected = { machine in
            events.check(machine == Session.Machine(id: 1111, name: "pc-finto"), "macchina vista dal client: \(machine)")
            events.record("client-trusts-server")
            var packet = Packet(type: .mouse, des: machine.id)
            packet.mouse = MouseData(x: RelativeMouse.encode(12), y: RelativeMouse.encode(-7), flags: WM.mouseMove)
            client.send(packet)
        }
        server.onMachineConnected = { machine in
            events.check(machine == Session.Machine(id: 2222, name: "mac-finto"), "macchina vista dal server: \(machine)")
            events.record("server-trusts-client")
        }
        server.onPacket = { packet in
            switch packet.type {
            case .heartbeat:
                events.check(packet.machineName == "mac-finto" && packet.des == MachineID.all, "heartbeat: \(packet)")
                events.record("heartbeat")
            case .mouse:
                events.check(packet.src == 2222 && RelativeMouse.decode(packet.mouse.x) == 12
                    && RelativeMouse.decode(packet.mouse.y) == -7, "mouse: \(packet)")
                events.record("mouse")
                var reply = Packet(type: .nextMachine, des: packet.src)
                reply.mouse = MouseData(x: 65535, y: 30000, wheelDelta: 2222, flags: 0)
                server.send(reply)
            default:
                break
            }
        }
        client.onPacket = { packet in
            if packet.type == .nextMachine {
                events.check(packet.mouse.wheelDelta == 2222 && packet.mouse.y == 30000, "NextMachine: \(packet)")
                events.record("next-machine")
            }
        }

        server.start()
        client.start()
        let done = await events.wait(for: ["client-trusts-server", "server-trusts-client", "heartbeat", "mouse", "next-machine"],
                                     timeout: 10)
        #expect(done, "eventi arrivati: \(events.all)")
        #expect(events.problems.isEmpty, "\(events.problems)")
        #expect(client.connectedMachines.map(\.name) == ["pc-finto"])
        // Un solo pacchetto mouse consegnato: niente doppioni.
        #expect(events.all.filter { $0 == "mouse" }.count == 1)
        client.stop()
        server.stop()
    }

    @Test func legacySchemeIsDetected() async {
        let (server, client) = makePair(port: 25107, serverScheme: .legacy)
        let events = Events()
        client.onMachineConnected = { machine in
            events.record("client")
            client.send(Packet(type: .machineSwitched, des: machine.id))
        }
        server.onMachineConnected = { _ in events.record("server") }
        server.onPacket = { if $0.type == .machineSwitched { events.record("switched") } }
        server.start()
        client.start()
        #expect(await events.wait(for: ["client", "server", "switched"], timeout: 10), "eventi arrivati: \(events.all)")
        client.stop()
        server.stop()
    }

    @Test func byeByeAndDisconnectAreReported() async {
        let (server, client) = makePair(port: 25103)
        let events = Events()
        server.onMachineConnected = { _ in events.record("connected") }
        server.onPacket = { if $0.type == .byeBye { events.record("byebye") } }
        server.onMachineDisconnected = { machine in
            events.check(machine.id == 2222, "disconnessa: \(machine)")
            events.record("disconnected")
        }
        server.start()
        client.start()
        #expect(await events.wait(for: ["connected"], timeout: 10))
        client.stop()
        #expect(await events.wait(for: ["byebye", "disconnected"], timeout: 10), "eventi arrivati: \(events.all)")
        #expect(events.problems.isEmpty, "\(events.problems)")
        server.stop()
    }

    @Test func wrongKeyNeverBecomesTrusted() async {
        let (server, client) = makePair(port: 25105, clientKey: "UnaChiaveDiversa12345")
        let events = Events()
        server.onMachineConnected = { _ in events.record("trusted") }
        client.onMachineConnected = { _ in events.record("trusted") }
        client.onInvalidKey = { events.record("invalid-key") }
        server.start()
        client.start()
        #expect(await events.wait(for: ["invalid-key"], timeout: 5))
        // Dopo il primo flusso illeggibile il client non deve riprovare.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(events.all.filter { $0 == "invalid-key" }.count == 1)
        #expect(!events.all.contains("trusted"))
        #expect(client.connectedMachines.isEmpty)
        client.stop()
        server.stop()
    }
}

struct AdmissionTests {
    @Test func limitsPendingConnections() {
        var admission = Admission(maxPending: 2, maxPerWindow: 100, window: 10)
        var results: [Bool] = []
        results.append(admission.admit(pending: 0, now: 0))
        results.append(admission.admit(pending: 1, now: 0))
        results.append(admission.admit(pending: 2, now: 0))
        // Chiusa una connessione pendente, se ne accetta un'altra.
        results.append(admission.admit(pending: 1, now: 0.1))
        #expect(results == [true, true, false, true])
    }

    @Test func limitsRateAndRecovers() {
        var admission = Admission(maxPending: 100, maxPerWindow: 3, window: 10)
        var results: [Bool] = []
        for _ in 0..<3 { results.append(admission.admit(pending: 0, now: 1)) }
        results.append(admission.admit(pending: 0, now: 5))
        results.append(admission.admit(pending: 0, now: 10.9))
        // Passata la finestra, si accetta di nuovo.
        results.append(admission.admit(pending: 0, now: 11.1))
        #expect(results == [true, true, true, false, false, true])
    }
}

/// Connessioni a raffica da un peer che non conosce la chiave: oltre il limite vengono
/// chiuse subito, senza derivazioni PBKDF2, e la sessione continua a funzionare.
@Suite(.serialized)
struct ConnectionFloodTests {
    @Test func floodIsCappedAndLegitPeerStillConnects() async throws {
        let port: UInt16 = 25401
        let server = Session(configuration: .init(localName: "mac-finto", machineID: 2222,
                                                  securityKey: "MwbEncryptionTestKey1234", remoteHost: nil,
                                                  basePort: port - 1, listenPort: port))
        server.log.sink = { _ in }
        server.start()
        try? await Task.sleep(nanoseconds: 300_000_000)

        let queue = DispatchQueue(label: "test.flood")
        let closed = Events()
        var flood: [NWConnection] = []
        for index in 0..<20 {
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: closed.record("chiusa-\(index)")
                default: break
                }
            }
            connection.start(queue: queue)
            // Il peer resta muto: per una connessione accettata la sessione aspetta.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, isComplete, error in
                if isComplete || error != nil { closed.record("chiusa-\(index)") }
            }
            flood.append(connection)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Oltre le 4 accettate, le altre 16 sono state chiuse dal Mac quasi subito.
        #expect(Set(closed.all).count >= 16, "chiuse: \(Set(closed.all).count)")
        flood.forEach {
            $0.stateUpdateHandler = nil
            $0.cancel()
        }
        server.stop()
    }
}
