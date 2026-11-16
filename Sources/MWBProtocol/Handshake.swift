// Handshake a sfida. Fonte: PowerToys `SocketStuff.MainTCPRoutine`.
//
// Ogni lato invia 10 pacchetti `Handshake` identici con 16 byte casuali in `Machine1..4`;
// il ricevente risponde a ciascuno con `HandshakeAck` contenente il complemento bit a bit,
// il proprio MachineId in `Src` e il proprio nome. Chi ha lanciato la sfida considera
// fidato il peer al primo Ack corretto e ne ricava ID e nome.

public enum Handshake {
    public static let repeatCount = 10

    /// Sfida da inviare all'apertura della connessione.
    public static func challenge(localName: String, localID: UInt32, random: [UInt8]? = nil) -> Packet {
        var packet = Packet(type: .handshake, machineName: localName)
        packet.src = localID
        packet.payload = random ?? KeyDerivation.randomBytes(Packet.payloadSize)
        precondition(packet.payload.count == Packet.payloadSize)
        return packet
    }

    /// Risposta a una sfida ricevuta.
    public static func ack(for challenge: Packet, localName: String, localID: UInt32) -> Packet {
        var packet = challenge
        packet.rawType = PackageType.handshakeAck.rawValue
        packet.src = localID
        packet.machineName = localName
        packet.payload = challenge.payload.map { ~$0 }
        return packet
    }

    /// Vero se `ack` risponde correttamente alla nostra sfida.
    public static func isValid(ack: Packet, for challenge: Packet) -> Bool {
        ack.type == .handshakeAck && ack.payload == challenge.payload.map { ~$0 }
    }
}
