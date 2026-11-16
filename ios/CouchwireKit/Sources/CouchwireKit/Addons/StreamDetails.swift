import Foundation

// Turning an add-on's stream (docs/api/responses/stream.md in Stremio's add-on SDK) into a row the phone shows,
// and choosing the one Play starts. The TV plays web links itself, so only `url` streams over http(s) are kept;
// every other kind of source is left out.
//
// What the phone can tell about a stream is what helps decide whether the TV will play it well: picture size, HDR,
// video and audio formats, file size and spoken languages, read from the stream's name and description.

enum StreamDetails {
    /// The row for one stream, or nil when the TV can't open it.
    static func option(from json: JSONObject, addon: String) -> StreamOption? {
        guard let url = json.text("url") else { return nil }
        let scheme = url.prefix(8).lowercased()
        guard scheme.hasPrefix("https://") || scheme.hasPrefix("http://") else { return nil }

        let hints = json.object("behaviorHints") ?? [:]
        // Links that only work with extra request headers: the TV's player can't send them.
        if let headers = hints.object("proxyHeaders")?.object("request"), !headers.isEmpty { return nil }

        let name = json.text("name")
        let description = json.text("description") ?? json.text("title")
        let filename = hints.text("filename")
        let text = [name, description, filename].compactMap { $0 }.joined(separator: "\n")

        let quality = Detect.first(in: text, Detect.quality)
        let hdr = Detect.first(in: text, Detect.hdr)
        let size = (hints.number("videoSize")).flatMap { $0 > 0 ? $0 : nil } ?? Detect.size(in: text)
        let sizeText = size.map(formatBytes)

        let lines = (description ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let title = lines.isEmpty ? (name.map(oneLine) ?? addon) : lines.joined(separator: " · ")

        let summary = [[quality, hdr].compactMap { $0 }.joined(separator: " "), sizeText ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let label = summary.isEmpty ? (name.map(oneLine) ?? addon) : summary

        return StreamOption(url: url, addon: addon, name: name, title: title, filename: filename,
                            quality: quality, videoCodec: Detect.first(in: text, Detect.videoCodec),
                            audioCodec: Detect.first(in: text, Detect.audioCodec), hdr: hdr, size: sizeText,
                            languages: Detect.languages(in: text), label: label)
    }

    /// The stream Play starts. "auto" takes the add-ons' own order; a quality ("4K", "1080p", "720p") takes the first
    /// stream of that quality, else the closest one below it, else the first. Either way, streams whose sound the TV
    /// may not play are passed over while there is another choice.
    static func best(_ options: [StreamOption], quality preferred: String) -> StreamOption? {
        let playable = options.filter { !Detect.soundMayNotPlay($0.audioCodec) }
        let pool = playable.isEmpty ? options : playable
        guard let wanted = rank(preferred) else { return pool.first }
        if let exact = pool.first(where: { $0.quality == preferred }) { return exact }
        let lower = pool.compactMap { option in rank(option.quality).flatMap { $0 < wanted ? $0 : nil } }
        if let closest = lower.max() {
            return pool.first { rank($0.quality) == closest }
        }
        return pool.first
    }

    static func rank(_ quality: String?) -> Int? {
        switch quality {
        case "4K": return 6
        case "1440p": return 5
        case "1080p": return 4
        case "720p": return 3
        case "480p": return 2
        case "360p": return 1
        default: return nil
        }
    }

    static func formatBytes(_ bytes: Double) -> String {
        let gigabytes = bytes / 1_000_000_000
        if gigabytes >= 10 { return String(format: "%.0f GB", gigabytes) }
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        return String(format: "%.0f MB", max(bytes / 1_000_000, 1))
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Recognising a few well-known words in a stream's description.
enum Detect {
    typealias Rule = (label: String, pattern: NSRegularExpression)

    private static func rules(_ list: [(String, String)]) -> [Rule] {
        list.map { label, pattern in
            (label, try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
        }
    }

    // Each list goes from the most specific to the least: the first label found is the one kept.
    static let quality = rules([
        ("4K", #"\b(2160p|4k|uhd)\b"#),
        ("1440p", #"\b1440p\b"#),
        ("1080p", #"\b(1080p|1080i|fhd)\b"#),
        ("720p", #"\b720p\b"#),
        ("480p", #"\b(480p|576p)\b"#),
        ("360p", #"\b360p\b"#),
    ])

    static let hdr = rules([
        ("DV", #"\b(dolby[ .-]?vision|dovi)\b"#),
        ("HDR10+", #"\bhdr10(\+|plus)"#),
        ("HDR", #"\bhdr(10)?\b"#),
    ])

    static let videoCodec = rules([
        ("HEVC", #"\b(hevc|h\.?265|x265)\b"#),
        ("AV1", #"\bav1\b"#),
        ("H.264", #"\b(avc|h\.?264|x264)\b"#),
        ("VP9", #"\bvp9\b"#),
    ])

    static let audioCodec = rules([
        ("TrueHD", #"\btrue[ .-]?hd\b"#),
        ("DTS", #"\bdts\b"#),
        ("DD+", #"(\be-?ac-?3\b|\bddp|\bdd\+|dolby digital plus)"#),
        ("DD", #"\b(ac-?3|dd[ .]?[257]\.[01])\b"#),
        ("AAC", #"\baac\b"#),
        ("Opus", #"\bopus\b"#),
    ])

    private static let languageWords = rules([
        ("English", #"\benglish\b"#),
        ("Spanish", #"\b(spanish|español|espanol|castellano|latino)\b"#),
        ("French", #"\b(french|français|francais)\b"#),
        ("German", #"\b(german|deutsch)\b"#),
        ("Italian", #"\b(italian|italiano)\b"#),
        ("Portuguese", #"\b(portuguese|português|portugues)\b"#),
        ("Japanese", #"\bjapanese\b"#),
        ("Korean", #"\bkorean\b"#),
        ("Multi", #"\b(multi|dual[ .-]?audio)\b"#),
    ])

    private static let flags: [(String, String)] = [
        ("🇬🇧", "English"), ("🇺🇸", "English"), ("🇪🇸", "Spanish"), ("🇲🇽", "Spanish"), ("🇫🇷", "French"),
        ("🇩🇪", "German"), ("🇮🇹", "Italian"), ("🇵🇹", "Portuguese"), ("🇧🇷", "Portuguese"), ("🇯🇵", "Japanese"),
        ("🇰🇷", "Korean"), ("🇨🇳", "Chinese"), ("🇷🇺", "Russian"), ("🇳🇱", "Dutch"), ("🇵🇱", "Polish"),
        ("🇹🇷", "Turkish"), ("🇮🇳", "Hindi"),
    ]

    static func first(in text: String, _ rules: [Rule]) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        return rules.first { $0.pattern.firstMatch(in: text, range: range) != nil }?.label
    }

    static func languages(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        for (flag, language) in flags where text.contains(flag) && !found.contains(language) {
            found.append(language)
        }
        for rule in languageWords where rule.pattern.firstMatch(in: text, range: range) != nil
            && !found.contains(rule.label) {
            found.append(rule.label)
        }
        return found
    }

    private static let sizePattern = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d+)?)\s?(TB|GB|MB|TiB|GiB|MiB)\b"#, options: [.caseInsensitive])

    /// A file size written in the description ("4.2 GB"), in bytes.
    static func size(in text: String) -> Double? {
        guard let match = sizePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let unit: Double
        switch text[unitRange].uppercased() {
        case "TB": unit = 1_000_000_000_000
        case "TIB": unit = 1_099_511_627_776
        case "GB": unit = 1_000_000_000
        case "GIB": unit = 1_073_741_824
        case "MIB": unit = 1_048_576
        default: unit = 1_000_000
        }
        return number * unit
    }

    /// Sound formats LG's web player may not decode; Play prefers a stream without them.
    static func soundMayNotPlay(_ audio: String?) -> Bool {
        audio == "TrueHD" || audio == "DTS"
    }
}
