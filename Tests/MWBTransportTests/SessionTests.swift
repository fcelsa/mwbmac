import Foundation
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
    private func makePair(port: UInt16, clientKey: String = "MwbEncryptionTestKey1234") -> (server: Session, client: Session) {
        let server = Session(configuration: .init(localName: "pc-finto", machineID: 1111,
                                                  securityKey: "MwbEncryptionTestKey1234", remoteHost: nil,
                                                  basePort: port - 1, listenPort: port))
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
        server.start()
        client.start()
        #expect(await events.wait(for: ["trusted"], timeout: 2.5) == false)
        #expect(client.connectedMachines.isEmpty)
        client.stop()
        server.stop()
    }
}
