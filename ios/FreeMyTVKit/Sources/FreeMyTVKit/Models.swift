import Foundation

// What the Pi's API (v1) answers: see pi/API.md. Image and link fields stay strings (an add-on can send an empty or
// odd value, which must not fail the whole answer); the `...URL` properties turn them into URLs.

public enum MediaType: String, Codable, Sendable, Hashable {
    case movie, series
}

func link(_ value: String?) -> URL? {
    guard let value, !value.isEmpty, value.hasPrefix("http") else { return nil }
    return URL(string: value)
}

/// A title on a row, in search results or in the library.
public struct Card: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: MediaType
    public let name: String
    public let poster: String?
    public let posterShape: String?
    public let background: String?
    public let logo: String?
    public let year: String?
    public let rating: String?
    public let description: String?

    public init(id: String, type: MediaType, name: String, poster: String? = nil, posterShape: String? = nil,
                background: String? = nil, logo: String? = nil, year: String? = nil, rating: String? = nil,
                description: String? = nil) {
        self.id = id
        self.type = type
        self.name = name
        self.poster = poster
        self.posterShape = posterShape
        self.background = background
        self.logo = logo
        self.year = year
        self.rating = rating
        self.description = description
    }

    public var posterURL: URL? { link(poster) }
    public var backgroundURL: URL? { link(background) }
    public var logoURL: URL? { link(logo) }
}

public struct Row: Codable, Sendable, Hashable, Identifiable {
    public let addon: String
    public let addonName: String
    public let type: String
    public let catalog: String
    public let title: String
    public let items: [Card]

    public var id: String { "\(addon)/\(type)/\(catalog)" }
}

/// A Continue watching card: where to pick up.
public struct Resume: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: MediaType
    public let name: String
    public let poster: String?
    public let background: String?
    public let logo: String?
    public let videoId: String
    public let season: Int?
    public let episode: Int?
    public let episodeTitle: String?
    public let progress: Double
    public let remainingMs: Double

    public var posterURL: URL? { link(poster) }
    public var backgroundURL: URL? { link(background) }
    public var logoURL: URL? { link(logo) }
    public var card: Card { Card(id: id, type: type, name: name, poster: poster, background: background, logo: logo) }
}

public struct Home: Codable, Sendable {
    public let continueWatching: [Resume]
    /// nil: the add-ons couldn't be reached.
    public let rows: [Row]?
}

public struct Items: Codable, Sendable {
    public let items: [Card]
}

public struct SearchResults: Codable, Sendable {
    public let movies: [Card]
    public let series: [Card]
}

public struct Video: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let season: Int
    public let episode: Int
    public let title: String?
    public let overview: String?
    public let thumbnail: String?
    public let released: String?
    public let progress: Double
    public let watched: Bool

    public var thumbnailURL: URL? { link(thumbnail) }
    public var releaseDate: Date? { released.flatMap(parseDate) }
    public var hasAired: Bool { releaseDate.map { $0 <= Date() } ?? true }
}

func parseDate(_ text: String) -> Date? {
    let full = ISO8601DateFormatter()
    full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = full.date(from: text) { return date }
    full.formatOptions = [.withInternetDateTime]
    if let date = full.date(from: text) { return date }
    full.formatOptions = [.withFullDate]
    return full.date(from: String(text.prefix(10)))
}

/// A title's page.
public struct Title: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let type: MediaType
    public let name: String
    public let poster: String?
    public let background: String?
    public let logo: String?
    public let year: String?
    public let rating: String?
    public let description: String?
    public let addonName: String?
    public let runtime: String?
    public let released: String?
    public let country: String?
    public let genres: [String]
    public let cast: [String]
    public let director: [String]
    public let certification: String?
    public let status: String?
    public let trailer: String?
    public let inLibrary: Bool
    /// A movie's progress (0...1).
    public let progress: Double?
    public let videos: [Video]

    public var posterURL: URL? { link(poster) }
    public var backgroundURL: URL? { link(background) }
    public var logoURL: URL? { link(logo) }
    public var card: Card {
        Card(id: id, type: type, name: name, poster: poster, background: background, logo: logo, year: year,
             rating: rating, description: description)
    }

    /// Seasons in order, specials (season 0) last.
    public var seasons: [Int] {
        let all = Set(videos.map(\.season))
        return all.filter { $0 > 0 }.sorted() + (all.contains(0) ? [0] : [])
    }

    /// The episode Play means: the one in progress, else the first unwatched one after the last watched, else the first.
    public var nextEpisode: Video? {
        let aired = videos.filter { $0.season > 0 && $0.hasAired }
        if let started = aired.last(where: { $0.progress > 0.02 && !$0.watched }) { return started }
        if let lastWatched = aired.lastIndex(where: \.watched) {
            return aired.indices.contains(lastWatched + 1) ? aired[lastWatched + 1] : aired.first
        }
        return aired.first
    }
}

public struct StreamOption: Codable, Sendable, Hashable, Identifiable {
    public let url: String
    public let addon: String
    public let name: String?
    public let title: String
    public let filename: String?
    public let quality: String?
    public let source: String?
    public let videoCodec: String?
    public let audioCodec: String?
    public let hdr: String?
    public let size: String?
    public let languages: [String]
    public let cached: Bool
    public let label: String

    public var id: String { url }
}

public struct Streams: Codable, Sendable {
    public let best: String?
    public let streams: [StreamOption]
}

public struct Profile: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String
    public let color: String?
    public let avatar: String?

    public var avatarURL: URL? { link(avatar) }
}

public struct User: Codable, Sendable, Hashable {
    public let id: String
    public let email: String?
}

public struct LoginResult: Codable, Sendable {
    public let token: String
    public let user: User
}

public struct Me: Codable, Sendable {
    public let user: User
    public let profile: Int?
}

public struct ServerInfo: Codable, Sendable {
    public let name: String
    public let api: Int
}

public struct PlayResult: Codable, Sendable {
    public let job: Int?
    public let title: String
    public let label: String
    public let url: String
}

// MARK: The TV (through the Pi's TV service)

public struct TVJob: Codable, Sendable, Hashable {
    public let id: Int
    public let step: String
    public let done: Bool
    public let ok: Bool
    public let title: String
}

public struct TVStatus: Codable, Sendable, Hashable {
    /// on, standby or off
    public let power: String
    public let app: String?
    public let appTitle: String?
    /// playing, paused, ...
    public let media: String?
    public let volume: Int?
    public let muted: Bool?
    public let job: TVJob?

    public var isOn: Bool { power == "on" }

    public var summary: String {
        if power == "off" { return "Off" }
        if power == "standby" { return "Standby" }
        if media == "playing" { return "Playing in \(appTitle ?? "an app")" }
        if media == "paused" { return "Paused in \(appTitle ?? "an app")" }
        return appTitle.map { "On: \($0)" } ?? "On"
    }
}

public struct TVInput: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
}

public struct TVInputs: Codable, Sendable {
    public let inputs: [TVInput]
}

/// An answer whose content doesn't matter.
public struct Done: Codable, Sendable {}
