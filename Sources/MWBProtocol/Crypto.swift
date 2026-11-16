// Derivazione della chiave, magic number e cifratura a flusso.
// Fonte: PowerToys `Core/Encryption.cs`.
//
// Ogni direzione di ogni connessione inizia con 32 byte in chiaro (16 di salt + 16 di IV);
// da lì in poi il flusso è AES-256-CBC senza padding effettivo (i pacchetti sono multipli
// di 16 byte). Il primo blocco cifrato è un blocco casuale da scartare
// (`Common.SendOrReceiveARandomDataBlockPerInitialIV`).

import CommonCrypto

public enum CryptoError: Error {
    case keyDerivationFailed(Int32)
    case cryptorFailed(Int32)
    case invalidParameter
}

public enum KeyDerivation {
    public static let saltSize = 16
    public static let blockSize = 16
    public static let headerSize = saltSize + blockSize
    public static let iterations: UInt32 = 100_000
    public static let derivedKeyLength = 32

    /// PowerToys scarta gli spazi dalla security key inserita dall'utente.
    public static func normalize(securityKey: String) -> String {
        String(securityKey.unicodeScalars.filter { !$0.properties.isWhitespace })
    }

    /// PBKDF2-HMAC-SHA512, 100000 iterazioni, 32 byte (`Encryption.GenLegalKey`).
    /// La password è la security key in UTF-8, come fa `Rfc2898DeriveBytes.Pbkdf2(string, …)`.
    public static func deriveKey(securityKey: String, salt: [UInt8],
                                 iterations: UInt32 = KeyDerivation.iterations) throws -> [UInt8] {
        let password = Array(securityKey.utf8)
        var derived = [UInt8](repeating: 0, count: derivedKeyLength)
        let status = password.withUnsafeBufferPointer { passwordPointer in
            passwordPointer.withMemoryRebound(to: CChar.self) { chars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     chars.baseAddress, password.count,
                                     salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                                     iterations,
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.keyDerivationFailed(status) }
        return derived
    }

    /// Magic number a 24 bit derivato dalla security key (`Encryption.Get24BitHash`):
    /// SHA-512 dei primi 32 caratteri (byte basso di ogni unità UTF-16, riempito con zeri),
    /// poi altre 50000 applicazioni di SHA-512. Solo i 16 bit alti finiscono nei pacchetti.
    public static func magicNumber(securityKey: String) -> UInt32 {
        guard !securityKey.isEmpty else { return 0 }
        var bytes = [UInt8](repeating: 0, count: Packet.size)
        for (index, unit) in securityKey.utf16.prefix(Packet.size).enumerated() {
            bytes[index] = UInt8(truncatingIfNeeded: unit)
        }
        var hash = sha512(bytes)
        for _ in 0..<50_000 { hash = sha512(hash) }
        return (UInt32(hash[0]) << 23) &+ (UInt32(hash[1]) << 16) &+ (UInt32(hash[63]) << 8) &+ UInt32(hash[2])
    }

    static func sha512(_ input: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
        _ = CC_SHA512(input, CC_LONG(input.count), &digest)
        return digest
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// AES-256-CBC in modalità streaming: lo stato di concatenazione prosegue fra una
/// chiamata e l'altra, come il `CryptoStream` di .NET usato da PowerToys.
public final class CipherStream {
    public enum Direction { case encrypt, decrypt }

    private var cryptor: CCCryptorRef?

    public init(key: [UInt8], iv: [UInt8], direction: Direction) throws {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else {
            throw CryptoError.invalidParameter
        }
        let operation = direction == .encrypt ? kCCEncrypt : kCCDecrypt
        // Opzioni 0 = CBC senza padding PKCS7.
        let status = CCCryptorCreate(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), 0,
                                     key, key.count, iv, &cryptor)
        guard status == kCCSuccess, cryptor != nil else { throw CryptoError.cryptorFailed(status) }
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    /// Elabora i byte in ingresso; restituisce i blocchi completi disponibili
    /// (eventuali byte residui restano nel buffer interno di CommonCrypto).
    public func process(_ input: [UInt8]) throws -> [UInt8] {
        guard !input.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw CryptoError.cryptorFailed(status) }
        output.removeLast(output.count - moved)
        return output
    }
}
