import Foundation

// Reading a stream's label (quality, source, codecs, size, languages) and picking the best one, as the Nuvio Web
// fork does (stream-format.ts): the same patterns, so the phone picks what the Pi picked.

/// A stream as an add-on sent it, with the add-on's name.
public struct RawStream: Hashable, Sendable {
    public let url: String?
    public let notWebReady: Bool
    public let name: String?
    public let title: String?
    public let description: String?
    public let addonName: String
    public let fileSize: Double?
    public let infoHash: String?
    public let filename: String?

    init?(json: Any, addonName: String) {
        guard let object = json as? JSON else { return nil }
        let hints = object["behaviorHints"] as? JSON
        let link = string(object["url"])
        url = link.flatMap { $0.hasPrefix("http://") || $0.hasPrefix("https://") ? $0 : nil }
        notWebReady = hints?["notWebReady"] as? Bool == true
        name = string(object["name"])
        title = string(object["title"])
        description = string(object["description"])
        self.addonName = addonName
        fileSize = (hints?["videoSize"] as? NSNumber)?.doubleValue
        infoHash = string(object["infoHash"])
        filename = string(hints?["filename"])
    }

    var rawLabel: String { [name, title, description].compactMap { $0 }.joined(separator: "\n") }

    var flatLabel: String {
        (rawLabel + " " + (filename ?? "")).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A link the TV can open as it is.
    var isPlayable: Bool { url != nil && !notWebReady }
}

private struct Pattern {
    let regex: NSRegularExpression
    let label: String

    init(_ pattern: String, _ label: String) {
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        self.label = label
    }

    func test(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

private func firstMatch(_ text: String, _ patterns: [Pattern]) -> String? {
    patterns.first { $0.test(text) }?.label
}

private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private let qualityTokens = [
    Pattern(#"\b(2160p|4k|uhd)\b"#, "4K"), Pattern(#"\b1440p\b"#, "1440p"), Pattern(#"\b1080p\b"#, "1080p"),
    Pattern(#"\b720p\b"#, "720p"), Pattern(#"\b480p\b"#, "480p"), Pattern(#"\b360p\b"#, "360p"),
]

private let sourceTokens = [
    Pattern(#"\bremux\b"#, "REMUX"), Pattern(#"\b(blu-?ray|bdrip|bd-?remux)\b"#, "BluRay"),
    Pattern(#"\bweb-?dl\b"#, "WEB-DL"), Pattern(#"\bweb-?rip\b"#, "WEBRip"), Pattern(#"\bhdtv\b"#, "HDTV"),
    Pattern(#"\b(dvdrip|dvd-?r)\b"#, "DVD"), Pattern(#"\b(cam|hdcam|ts|telesync)\b"#, "CAM"),
]

private let videoCodecTokens = [
    Pattern(#"\b(av1)\b"#, "AV1"), Pattern(#"\b(x265|hevc|h\.?265)\b"#, "HEVC"),
    Pattern(#"\b(x264|avc|h\.?264)\b"#, "H.264"), Pattern(#"\b(xvid|divx|mpeg-?4)\b"#, "MPEG-4"),
]

private let audioCodecTokens = [
    Pattern(#"\batmos\b"#, "Atmos"), Pattern(#"\b(true-?hd)\b"#, "TrueHD"),
    Pattern(#"\b(dts-?hd|dts\s?ma|dts-?x)\b"#, "DTS-HD"), Pattern(#"\bdts\b"#, "DTS"),
    Pattern(#"\b(e-?ac-?3|eac3|dd\s?\+|ddp\d?\.?\d?|dolby\s?digital\s?plus)\b"#, "DD+"),
    Pattern(#"\b(ac-?3|dd\s?[0-9]\.[0-9]|dolby\s?digital)\b"#, "DD"), Pattern(#"\bflac\b"#, "FLAC"),
    Pattern(#"\b(opus)\b"#, "Opus"), Pattern(#"\b(aac|he-?aac|lc-?aac)\b"#, "AAC"), Pattern(#"\b(mp3)\b"#, "MP3"),
    Pattern(#"\b(pcm|lpcm)\b"#, "PCM"),
]

private let riskyAudio = [
    Pattern(#"\b(atmos)\b"#, "Atmos"),
    Pattern(#"\b(e-?ac-?3|eac3|dd\s?\+|ddp\d?\.?\d?|dolby\s?digital\s?plus)\b"#, "EAC3"),
    Pattern(#"\b(ac-?3|dd\s?[257]\.[01]|dd\b|dolby\s?digital)\b"#, "AC3"),
    Pattern(#"\b(dts-?hd|dts-?x|dts-?es|dts\s?ma|dts)\b"#, "DTS"), Pattern(#"\b(true-?hd|mlp)\b"#, "TrueHD"),
    Pattern(#"\b(l?pcm)\b"#, "PCM"),
]
private let safeAudio = regex(#"\b(aac|opus|mp3|vorbis|e-ac-3 to aac|→\s?aac|to aac)\b"#)

private let dolbyVision = regex(#"\bdolby\s?vision\b|\bdv\b"#)
private let hdr10Plus = regex(#"\bhdr10\+"#)
private let hdr = regex(#"\bhdr\b"#)
private let multi = regex(#"\bmulti(?:-?(?:audio|sub))?\b"#)
private let dual = regex(#"\bdual[\s-]?audio\b"#)
private let sizePattern = regex(#"(\d+(?:\.\d+)?)\s?(TB|GB|MB|KB)\b"#)
private let flagPattern = try! NSRegularExpression(pattern: #"\p{Regional_Indicator}\p{Regional_Indicator}"#)
private let cachedPattern = try! NSRegularExpression(pattern: #"\[(RD|AD|PM|DL|TB|ED|OC|PP)\+\]|⚡"#)

public let qualityRank: [String: Int] = ["4K": 5, "1440p": 4, "1080p": 3, "720p": 2, "480p": 1, "360p": 0]

extension RawStream {
    /// The audio likely plays (no Dolby, DTS or TrueHD without an AAC copy).
    var audioIsSafe: Bool {
        let flat = flatLabel
        guard riskyAudio.contains(where: { $0.test(flat) }) else { return true }
        return matches(safeAudio, flat)
    }

    var quality: String? { firstMatch(rawLabel.replacingOccurrences(of: "\n", with: " "), qualityTokens) }

    var size: String? {
        if let fileSize, fileSize > 0 { return formatFileSize(fileSize) }
        let flat = flatLabel
        guard let match = sizePattern.firstMatch(in: flat, range: NSRange(flat.startIndex..., in: flat)),
              let number = Range(match.range(at: 1), in: flat), let unit = Range(match.range(at: 2), in: flat) else {
            return nil
        }
        return "\(flat[number]) \(flat[unit].uppercased())"
    }

    /// The release name, tidied: the file name, else the label's first line with letters in it.
    var releaseTitle: String {
        let candidate = filename ?? rawLabel.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                !line.isEmpty && line.rangeOfCharacter(from: .alphanumerics) != nil
                    && !line.hasPrefix("👤") && !line.hasPrefix("💾")
            }
        guard let candidate else { return addonName }
        var cleaned = candidate.replacingOccurrences(of: #"\.(mkv|mp4|avi|m4v|ts|webm)$"#, with: "",
                                                     options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.count > 90 ? String(cleaned.prefix(88)) + "…" : cleaned
    }

    var option: StreamOption? {
        guard let url else { return nil }
        let flat = flatLabel
        let raw = rawLabel
        let hdrLabel = matches(dolbyVision, flat) ? "DV" : matches(hdr10Plus, flat) ? "HDR10+"
            : matches(hdr, flat) ? "HDR" : nil
        var languages: [String] = []
        for match in flagPattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            if let range = Range(match.range, in: raw), !languages.contains(String(raw[range])) {
                languages.append(String(raw[range]))
            }
        }
        if matches(multi, flat) { languages.append("MULTI") }
        if matches(dual, flat) { languages.append("Dual") }
        let quality = firstMatch(flat, qualityTokens)
        let videoCodec = firstMatch(flat, videoCodecTokens)
        let audioCodec = firstMatch(flat, audioCodecTokens)
        let size = self.size
        let nameText = name ?? ""
        return StreamOption(
            url: url, addon: addonName, name: name, title: releaseTitle, filename: filename, quality: quality,
            source: firstMatch(flat, sourceTokens), videoCodec: videoCodec, audioCodec: audioCodec, hdr: hdrLabel,
            size: size, languages: languages,
            cached: cachedPattern.firstMatch(in: nameText, range: NSRange(nameText.startIndex..., in: nameText)) != nil,
            label: [quality, videoCodec, audioCodec, size].compactMap { $0 }.joined(separator: " · "))
    }
}

public func formatFileSize(_ bytes: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = bytes
    var unit = 0
    while value >= 1024 && unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return String(format: value >= 100 || unit < 2 ? "%.0f" : "%.1f", value) + " " + units[unit]
}

/// The best stream for a preferred quality ("auto": the add-ons' own order, skipping ones whose audio may not play).
func pickPreferred(_ streams: [RawStream], quality preferred: String = "auto") -> RawStream? {
    let playable = streams.filter(\.isPlayable)
    guard !playable.isEmpty else { return streams.first }
    guard let target = qualityRank[preferred] else {
        return playable.first(where: \.audioIsSafe) ?? playable.first
    }
    func distance(_ stream: RawStream) -> Int {
        guard let quality = stream.quality, let rank = qualityRank[quality] else { return 1 }
        return rank <= target ? target - rank : (rank - target) * 2
    }
    return playable.enumerated().min { a, b in
        let left = (distance(a.element), a.element.audioIsSafe ? 0 : 1, a.offset)
        let right = (distance(b.element), b.element.audioIsSafe ? 0 : 1, b.offset)
        return left < right
    }?.element
}
