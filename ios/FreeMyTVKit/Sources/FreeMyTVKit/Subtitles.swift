import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A timed subtitle line, as the TV draws it: start and end in seconds, and the text.
public struct Cue: Codable, Hashable, Sendable {
    public let s: Double
    public let e: Double
    public let t: String
}

/// Subtitles the TV couldn't read itself: the phone downloads the file (SRT or WebVTT, any common encoding, maybe
/// gzipped) and turns it into lines, as the Pi's subs.py did.
public enum SubtitleReader {
    public static func cues(from url: URL, session: URLSession = .shared) async throws -> [Cue] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("iStream/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AddonError(message: "The subtitle server said \(status)") }
        return parse(decode(data))
    }

    /// Text from the file's bytes: gunzipped when it's gzip, UTF-8 when it is, else Windows-1252.
    public static func decode(_ raw: Data) -> String {
        var data = raw
        if data.starts(with: [0x1f, 0x8b]), let inflated = gunzip(data) { data = inflated }
        if data.starts(with: [0xef, 0xbb, 0xbf]) { data = data.dropFirst(3) }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// A gzip file's content: its header skipped, the deflate stream inflated (Apple's "zlib" is raw deflate).
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0, index + 2 <= bytes.count {   // extra field
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 }   // name
        if flags & 0x10 != 0 { while index < bytes.count && bytes[index] != 0 { index += 1 }; index += 1 }   // comment
        if flags & 0x02 != 0 { index += 2 }   // header checksum
        guard index < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[index..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }

    private static let cueLine = try! NSRegularExpression(
        pattern: #"(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})"#)
    private static let tags = try! NSRegularExpression(pattern: #"<[^>]*>|\{\\[^}]*\}"#)

    /// SRT and WebVTT alike: every block with a "start --> end" line; the lines after it are the text.
    public static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n").split(whereSeparator: {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        })
        for block in blocks {
            let lines = Array(block)
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard let match = cueLine.firstMatch(in: line, range: range) else { continue }
                func group(_ n: Int) -> String? {
                    Range(match.range(at: n), in: line).map { String(line[$0]) }
                }
                func seconds(_ first: Int) -> Double {
                    let h = Double(group(first) ?? "0") ?? 0
                    let m = Double(group(first + 1) ?? "0") ?? 0
                    let s = Double(group(first + 2) ?? "0") ?? 0
                    let ms = Double(String(((group(first + 3) ?? "0") + "00").prefix(3))) ?? 0
                    return h * 3600 + m * 60 + s + ms / 1000
                }
                let start = seconds(1), end = seconds(5)
                let body = lines[(index + 1)...].map { line -> String in
                    let clean = tags.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line),
                                                              withTemplate: "")
                    return clean.trimmingCharacters(in: .whitespaces)
                }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty && end > start {
                    cues.append(Cue(s: (start * 1000).rounded() / 1000, e: (end * 1000).rounded() / 1000,
                                    t: String(body.prefix(400))))
                }
                break
            }
        }
        return cues.sorted { $0.s < $1.s }
    }
}
