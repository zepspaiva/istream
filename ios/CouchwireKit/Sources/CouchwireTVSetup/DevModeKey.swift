import Citadel
import CommonCrypto
import Crypto
import Foundation

/// The SSH key of an LG TV in Developer Mode. With Key Server on, the TV hands out its private key at
/// http://<TV>:9991/webos_rsa, locked with the passphrase the Developer Mode app shows on screen. The person types that
/// passphrase on the phone; the key is unlocked here and kept (unlocked) in the Keychain, so updates and renewals need
/// neither the passphrase nor Key Server again. The passphrase itself is never stored.
public enum DevModeKey {
    public enum Failure: LocalizedError, Equatable {
        case keyServerOff
        case wrongPassphrase
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .keyServerOff: "The TV's Key Server isn't answering. In the Developer Mode app on the TV, turn on Key Server."
            case .wrongPassphrase: "That passphrase didn't unlock the TV's key. Check it in the Developer Mode app on the TV (capital letters count)."
            case .unsupported(let what): "The TV's key is in a format Couchwire doesn't read yet (\(what))."
            }
        }
    }

    /// The locked key, from the TV's Key Server.
    public static func download(from ip: String) async throws -> String {
        guard let url = URL(string: "http://\(ip):9991/webos_rsa") else { throw Failure.keyServerOff }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        do {
            let (data, response) = try await URLSession(configuration: config).data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8),
                  text.contains("PRIVATE KEY")
            else { throw Failure.keyServerOff }
            return text
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.keyServerOff
        }
    }

    /// The key unlocked, as an unencrypted OpenSSH private key (the text to keep in the Keychain).
    /// Reads the classic PEM form ("BEGIN RSA PRIVATE KEY", with or without a passphrase) and the OpenSSH form when it
    /// isn't encrypted (what `ssh-keygen -p` leaves, so a key install.py already unlocked works too).
    public static func unlock(_ text: String, passphrase: String) throws -> String {
        if text.contains("BEGIN OPENSSH PRIVATE KEY") {
            _ = try privateKey(text)   // throws when it's encrypted or not RSA
            return text
        }
        guard text.contains("BEGIN RSA PRIVATE KEY") else {
            throw Failure.unsupported(text.contains("ENCRYPTED PRIVATE KEY") ? "PKCS#8" : "not an RSA key")
        }
        var headers: [String: String] = [:]
        var body = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("-----") { continue }
            if let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                body += line
            }
        }
        guard var der = Data(base64Encoded: body) else { throw Failure.unsupported("bad base64") }
        if headers["Proc-Type"]?.contains("ENCRYPTED") == true {
            guard let info = headers["DEK-Info"] else { throw Failure.unsupported("no DEK-Info") }
            der = try decrypt(der, dekInfo: info, passphrase: passphrase)
        }
        guard let rsa = PKCS1(der: der) else {
            // A wrong passphrase usually fails the padding check; when it doesn't, the DER doesn't parse.
            throw headers["Proc-Type"] == nil ? Failure.unsupported("bad key") : Failure.wrongPassphrase
        }
        return rsa.openSSH()
    }

    /// The key Citadel signs with.
    public static func privateKey(_ openSSH: String) throws -> Insecure.RSA.PrivateKey {
        do {
            return try Insecure.RSA.PrivateKey(sshRsa: openSSH)
        } catch {
            throw Failure.unsupported("OpenSSH key: \(error)")
        }
    }

    // MARK: PEM encryption (OpenSSL's "traditional" format)

    /// Key = MD5 chain over passphrase + the first 8 bytes of the IV (OpenSSL's EVP_BytesToKey, one round).
    static func decrypt(_ data: Data, dekInfo: String, passphrase: String) throws -> Data {
        let parts = dekInfo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let iv = Data(hex: parts[1]), iv.count >= 8 else { throw Failure.unsupported("DEK-Info") }
        let algorithm: CCAlgorithm
        let keyLength: Int
        switch parts[0].uppercased() {
        case "AES-128-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 16)
        case "AES-192-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 24)
        case "AES-256-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 32)
        case "DES-EDE3-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithm3DES), 24)
        default: throw Failure.unsupported(parts[0])
        }
        let salt = iv.prefix(8)
        var key = Data()
        var previous = Data()
        while key.count < keyLength {
            previous = Data(Insecure.MD5.hash(data: previous + Data(passphrase.utf8) + salt))
            key += previous
        }
        key = key.prefix(keyLength)

        var out = Data(count: data.count + 32)
        var moved = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), algorithm, CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, keyLength, ivBytes.baseAddress,
                                inBytes.baseAddress, data.count, outBytes.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.wrongPassphrase }
        return out.prefix(moved)
    }
}

// MARK: The RSA key itself

/// PKCS#1 RSAPrivateKey: SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }, all INTEGERs.
struct PKCS1 {
    let n, e, d, p, q, qinv: Data

    init?(der: Data) {
        var reader = DERReader(Array(der))
        guard var sequence = reader.read(tag: 0x30) else { return nil }
        var values: [Data] = []
        for _ in 0..<9 {
            guard let integer = sequence.readBytes(tag: 0x02) else { return nil }
            values.append(Data(integer))
        }
        guard values[0] == Data([0]), values[1].count >= 64 else { return nil }
        n = values[1]
        e = values[2]
        d = values[3]
        p = values[4]
        q = values[5]
        qinv = values[8]
    }

    private var publicBlob: SSHWriter {
        var blob = SSHWriter()
        blob.string("ssh-rsa")
        blob.mpint(e)
        blob.mpint(n)
        return blob
    }

    /// "ssh-rsa AAAA…", as in an authorized_keys file.
    var publicKeyLine: String { "ssh-rsa " + Data(publicBlob.bytes).base64EncodedString() }

    /// The same key as an unencrypted OpenSSH private key ("openssh-key-v1", cipher none).
    func openSSH(comment: String = "couchwire") -> String {

        var secret = SSHWriter()
        let check = UInt32.random(in: .min ... .max)
        secret.uint32(check)
        secret.uint32(check)
        secret.string("ssh-rsa")
        for value in [n, e, d, qinv, p, q] { secret.mpint(value) }
        secret.string(comment)
        var pad: UInt8 = 1
        while secret.bytes.count % 8 != 0 {
            secret.bytes.append(pad)
            pad += 1
        }

        var file = SSHWriter()
        file.bytes += Array("openssh-key-v1".utf8) + [0]
        file.string("none")
        file.string("none")
        file.string("")
        file.uint32(1)
        file.data(publicBlob.bytes)
        file.data(secret.bytes)

        let base64 = Data(file.bytes).base64EncodedString()
        var lines = ["-----BEGIN OPENSSH PRIVATE KEY-----"]
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        lines.append("-----END OPENSSH PRIVATE KEY-----")
        return lines.joined(separator: "\n") + "\n"
    }
}

struct DERReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// The contents of the next element, if it has this tag.
    mutating func readBytes(tag: UInt8) -> [UInt8]? {
        guard index < bytes.count, bytes[index] == tag else { return nil }
        index += 1
        guard index < bytes.count else { return nil }
        var length = Int(bytes[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        guard index + length <= bytes.count else { return nil }
        defer { index += length }
        return Array(bytes[index..<index + length])
    }

    mutating func read(tag: UInt8) -> DERReader? {
        readBytes(tag: tag).map(DERReader.init)
    }
}

struct SSHWriter {
    var bytes: [UInt8] = []

    mutating func uint32(_ value: UInt32) {
        bytes += [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    mutating func data(_ value: [UInt8]) {
        uint32(UInt32(value.count))
        bytes += value
    }

    mutating func string(_ value: String) { data(Array(value.utf8)) }

    /// A positive big number: no leading zero bytes, except one when the top bit is set.
    mutating func mpint(_ value: Data) {
        var digits = Array(value.drop { $0 == 0 })
        if let first = digits.first, first & 0x80 != 0 { digits.insert(0, at: 0) }
        data(digits)
    }
}

extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        while !chars.isEmpty {
            guard let byte = UInt8(String(chars.prefix(2)), radix: 16) else { return nil }
            bytes.append(byte)
            chars.removeFirst(2)
        }
        self.init(bytes)
    }
}
