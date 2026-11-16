import CouchwireKit
import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

// A backup of what this person keeps (their add-ons, library and progress) as one JSON file they save wherever they
// like (Files, iCloud Drive, AirDrop) and restore from on this or another device. There is no server: the file is the
// only copy outside the phone. Add-on addresses can hold personal keys, so the file is private data: it is never
// logged and never sent anywhere by the app.

struct CouchwireBackup: Codable {
    static let formatName = "couchwire-backup"
    static let currentVersion = 1

    struct LibraryEntry: Codable {
        var contentId: String
        var type: String
        var name: String
        var poster: String?
        var background: String?
        var year: String?
        var addedAt: Date
    }

    struct ProgressEntry: Codable {
        var contentId: String
        var type: String
        var videoId: String
        var season: Int?
        var episode: Int?
        var position: Double
        var duration: Double
        var updatedAt: Date
        var name: String
        var poster: String?
        var background: String?
        var episodeTitle: String?
        var nextVideoId: String?
        var nextSeason: Int?
        var nextEpisode: Int?
        var nextTitle: String?
    }

    var format = CouchwireBackup.formatName
    var version = CouchwireBackup.currentVersion
    var exportedAt = Date()
    /// Add-on manifest addresses, in the person's order.
    var addons: [String]
    var library: [LibraryEntry]?
    var progress: [ProgressEntry]?

    static func decode(_ data: Data) throws -> CouchwireBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(CouchwireBackup.self, from: data),
              backup.format == formatName else { throw BackupError.notABackup }
        guard backup.version <= currentVersion else { throw BackupError.tooNew }
        return backup
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    var suggestedFileName: String {
        let day = exportedAt.formatted(.iso8601.year().month().day())
        return "Couchwire backup \(day)"
    }
}

enum BackupError: LocalizedError {
    case notABackup, tooNew, unreadable

    var errorDescription: String? {
        switch self {
        case .notABackup: return "That file isn't a Couchwire backup."
        case .tooNew: return "That backup comes from a newer Couchwire. Update the app, then try again."
        case .unreadable: return "Couchwire couldn't open that file."
        }
    }
}

/// What a restore brought in, for the message on screen.
struct RestoreSummary {
    var addons = 0
    var library = 0
    var progress = 0

    var text: String {
        if addons + library + progress == 0 { return "Nothing new: you already had everything in that backup." }
        var parts: [String] = []
        if addons > 0 { parts.append(addons == 1 ? "1 add-on" : "\(addons) add-ons") }
        if library > 0 { parts.append(library == 1 ? "1 library title" : "\(library) library titles") }
        if progress > 0 { parts.append(progress == 1 ? "1 watch position" : "\(progress) watch positions") }
        return "Restored " + ListFormatter.localizedString(byJoining: parts) + "."
    }
}

/// The file the share sheet / Files picker writes.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw BackupError.unreadable }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension LocalStore {
    func makeBackup() -> CouchwireBackup {
        let library = library().map {
            CouchwireBackup.LibraryEntry(contentId: $0.contentId, type: $0.type, name: $0.name, poster: $0.poster,
                                         background: $0.background, year: $0.year, addedAt: $0.addedAt)
        }
        let records = (try? context.fetch(FetchDescriptor<WatchProgress>())) ?? []
        let progress = records.map {
            CouchwireBackup.ProgressEntry(contentId: $0.contentId, type: $0.type, videoId: $0.videoId,
                                          season: $0.season, episode: $0.episode, position: $0.position,
                                          duration: $0.duration, updatedAt: $0.updatedAt, name: $0.name,
                                          poster: $0.poster, background: $0.background,
                                          episodeTitle: $0.episodeTitle, nextVideoId: $0.nextVideoId,
                                          nextSeason: $0.nextSeason, nextEpisode: $0.nextEpisode,
                                          nextTitle: $0.nextTitle)
        }
        return CouchwireBackup(addons: addonURLs.map(\.manifest), library: library, progress: progress)
    }

    /// Merges a backup in; nothing already on the phone is removed. New add-ons go at the end, in the backup's
    /// order; missing library titles are added; a watch position is taken when the phone has none for that video
    /// or the backup's is newer.
    func restore(_ backup: CouchwireBackup) -> RestoreSummary {
        var summary = RestoreSummary()

        let before = addonURLs.count
        addAddons(backup.addons.compactMap { AddonURL($0) })
        summary.addons = addonURLs.count - before

        let inLibrary = Set(library().map(\.contentId))
        for entry in backup.library ?? [] where !inLibrary.contains(entry.contentId) && !entry.contentId.isEmpty {
            let item = LibraryItem(card: Card(id: entry.contentId, type: entry.type == "series" ? .series : .movie,
                                              name: entry.name, poster: entry.poster,
                                              background: entry.background, year: entry.year))
            item.type = entry.type
            item.addedAt = entry.addedAt
            context.insert(item)
            summary.library += 1
        }

        let records = (try? context.fetch(FetchDescriptor<WatchProgress>())) ?? []
        var byVideo = Dictionary(records.map { ($0.videoId, $0) }, uniquingKeysWith: { a, b in
            a.updatedAt >= b.updatedAt ? a : b
        })
        for entry in backup.progress ?? [] where !entry.videoId.isEmpty {
            if let existing = byVideo[entry.videoId], existing.updatedAt >= entry.updatedAt { continue }
            let record = byVideo[entry.videoId] ?? {
                let made = WatchProgress(contentId: entry.contentId, type: entry.type, videoId: entry.videoId)
                context.insert(made)
                return made
            }()
            record.contentId = entry.contentId
            record.type = entry.type
            record.season = entry.season
            record.episode = entry.episode
            record.position = entry.position
            record.duration = entry.duration
            record.updatedAt = entry.updatedAt
            record.name = entry.name
            record.poster = entry.poster
            record.background = entry.background
            record.episodeTitle = entry.episodeTitle
            record.nextVideoId = entry.nextVideoId
            record.nextSeason = entry.nextSeason
            record.nextEpisode = entry.nextEpisode
            record.nextTitle = entry.nextTitle
            byVideo[entry.videoId] = record
            summary.progress += 1
        }

        try? context.save()
        return summary
    }
}
