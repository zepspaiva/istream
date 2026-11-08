import Foundation

// What Free My TV tells the phone over LG's app-to-app channel (tv/web/channel.js).

/// What the phone knows the video as: for saving the place in the account.
public struct PlayerRef: Codable, Sendable, Hashable {
    public let type: String?
    public let contentId: String
    public let videoId: String
}

/// What the TV shows. `screen`: home, intro (the start screen), playing or paused.
public struct PlayerState: Codable, Sendable, Hashable {
    public let screen: String
    public let title: String?
    public let show: String?
    public let season: Int?
    public let episode: Int?
    public let episodeTitle: String?
    public let poster: String?
    public let backdrop: String?
    public let label: String?
    public let url: String?
    public let ref: PlayerRef?
    public let position: Double
    public let duration: Double
    public let buffering: Bool?

    public var isActive: Bool { screen == "intro" || screen == "playing" || screen == "paused" }
    public var isPlaying: Bool { screen == "playing" }
    public var artworkURL: URL? { link(backdrop) ?? link(poster) }
    public var name: String { show ?? title ?? "" }

    /// "S2 E3 · Office Olympics"
    public var episodeLine: String? {
        guard let season, let episode else { return nil }
        return "S\(season) E\(episode)" + (episodeTitle.map { " · \($0)" } ?? "")
    }

    static func decode(_ payload: [String: Any]) -> PlayerState? {
        decodeJSON(payload)
    }
}

public struct PlayerTrack: Codable, Sendable, Hashable {
    public let name: String
    public let lang: String?
    public let on: Bool
}

public struct PlayerTracks: Codable, Sendable, Hashable {
    public let audio: [PlayerTrack]
    public let subs: [PlayerTrack]

    public static let none = PlayerTracks(audio: [], subs: [])

    public init(audio: [PlayerTrack], subs: [PlayerTrack]) {
        self.audio = audio
        self.subs = subs
    }

    static func decode(_ payload: [String: Any]) -> PlayerTracks? {
        decodeJSON(payload)
    }
}

/// The Pi's pairing with the TV, handed to the app (GET /tv/pairing).
public struct TVPairing: Codable, Sendable, Hashable {
    public let ip: String
    public let clientKey: String?
    public let macs: [String]
}

func decodeJSON<T: Decodable>(_ object: [String: Any]) -> T? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}

extension PlayerState {
    /// Parses one of the channel's messages (`type: "state"`).
    public static func from(_ payload: [String: Any]) -> PlayerState? { decode(payload) }
}

extension PlayerTracks {
    /// Parses one of the channel's messages (`type: "tracks"`).
    public static func from(_ payload: [String: Any]) -> PlayerTracks? { decode(payload) }
}
