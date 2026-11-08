import CouchwireKit
import Foundation
import SwiftData

// What this person keeps: their add-ons, their library and where they got to. On the device for now (M4); shaped for
// iCloud (M5: every field has a default or is optional, nothing unique), so sync is a switch, not a migration.

@Model
final class SavedAddon {
    var url: String = ""
    var position: Int = 0
    var addedAt: Date = Date()

    init(url: String, position: Int) {
        self.url = url
        self.position = position
    }
}

@Model
final class LibraryItem {
    var contentId: String = ""
    var type: String = "movie"
    var name: String = ""
    var poster: String?
    var background: String?
    var year: String?
    var addedAt: Date = Date()

    init(card: Card) {
        contentId = card.id
        type = card.type.rawValue
        name = card.name
        poster = card.poster
        background = card.background
        year = card.year
    }

    var card: Card {
        Card(id: contentId, type: type == "series" ? .series : .movie, name: name, poster: poster,
             background: background, year: year)
    }
}

/// Where a movie or an episode got to (seconds), with what Continue watching shows about it.
@Model
final class WatchProgress {
    var contentId: String = ""
    var type: String = "movie"
    var videoId: String = ""
    var season: Int?
    var episode: Int?
    var position: Double = 0
    var duration: Double = 0
    var updatedAt: Date = Date()
    var name: String = ""
    var poster: String?
    var background: String?
    var episodeTitle: String?
    /// For a finished episode: the next one (found once, from the show's details).
    var nextVideoId: String?
    var nextSeason: Int?
    var nextEpisode: Int?
    var nextTitle: String?

    init(contentId: String, type: String, videoId: String) {
        self.contentId = contentId
        self.type = type
        self.videoId = videoId
    }

    var fraction: Double { duration > 0 ? min(1, position / duration) : 0 }
    var finished: Bool { fraction > 0.92 }
}

@MainActor
final class LocalStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init() {
        let schema = Schema([SavedAddon.self, LibraryItem.self, WatchProgress.self])
        do {
            container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration("Couchwire", schema: schema,
                                                                              cloudKitDatabase: .none))
        } catch {
            // A store that can't open (a format from a future version): start empty rather than not at all.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
    }

    // MARK: Add-ons

    var addonURLs: [AddonURL] {
        let saved = (try? context.fetch(FetchDescriptor<SavedAddon>(sortBy: [SortDescriptor(\.position)]))) ?? []
        return saved.compactMap { AddonURL($0.url) }
    }

    /// Adds the ones not there yet, at the end, in this order.
    func addAddons(_ urls: [AddonURL]) {
        var known = Set(addonURLs.map(\.base))
        var position = addonURLs.count
        for url in urls where known.insert(url.base).inserted {
            context.insert(SavedAddon(url: url.base, position: position))
            position += 1
        }
        try? context.save()
    }

    func removeAddon(_ url: AddonURL) {
        let saved = (try? context.fetch(FetchDescriptor<SavedAddon>())) ?? []
        for item in saved where item.url == url.base { context.delete(item) }
        try? context.save()
    }

    func moveAddons(_ order: [AddonURL]) {
        let saved = (try? context.fetch(FetchDescriptor<SavedAddon>())) ?? []
        for item in saved {
            item.position = order.firstIndex { $0.base == item.url } ?? order.count
        }
        try? context.save()
    }

    // MARK: Library

    func library() -> [LibraryItem] {
        (try? context.fetch(FetchDescriptor<LibraryItem>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)]))) ?? []
    }

    func isInLibrary(_ id: String) -> Bool { library().contains { $0.contentId == id } }

    func addToLibrary(_ card: Card) {
        guard !isInLibrary(card.id) else { return }
        context.insert(LibraryItem(card: card))
        try? context.save()
    }

    func removeFromLibrary(_ id: String) {
        for item in library() where item.contentId == id { context.delete(item) }
        try? context.save()
    }

    // MARK: Progress

    func progress(for contentId: String) -> [WatchProgress] {
        let all = (try? context.fetch(FetchDescriptor<WatchProgress>())) ?? []
        return all.filter { $0.contentId == contentId }
    }

    /// The record for this video, made when there's none.
    func progressRecord(contentId: String, type: String, videoId: String) -> WatchProgress {
        let all = (try? context.fetch(FetchDescriptor<WatchProgress>())) ?? []
        if let found = all.first(where: { $0.videoId == videoId }) { return found }
        let record = WatchProgress(contentId: contentId, type: type, videoId: videoId)
        context.insert(record)
        return record
    }

    func save() { try? context.save() }

    /// Continue watching: the latest video per title, newest first. An unfinished one resumes; a finished episode
    /// moves on to the next (once it's known); a finished movie drops out.
    func continueWatching(limit: Int = 20) -> [Resume] {
        let all = (try? context.fetch(FetchDescriptor<WatchProgress>(sortBy: [SortDescriptor(\.updatedAt,
                                                                                            order: .reverse)]))) ?? []
        var seen = Set<String>()
        var out: [Resume] = []
        for record in all where record.duration > 60 && seen.insert(record.contentId).inserted {
            let type: MediaType = record.type == "series" ? .series : .movie
            if !record.finished {
                guard record.fraction > 0.02 else { continue }
                out.append(Resume(id: record.contentId, type: type, name: record.name, poster: record.poster,
                                  background: record.background, logo: nil, videoId: record.videoId,
                                  season: record.season, episode: record.episode, episodeTitle: record.episodeTitle,
                                  progress: record.fraction,
                                  remainingMs: max(0, record.duration - record.position) * 1000))
            } else if let next = record.nextVideoId {
                out.append(Resume(id: record.contentId, type: type, name: record.name, poster: record.poster,
                                  background: record.background, logo: nil, videoId: next,
                                  season: record.nextSeason, episode: record.nextEpisode,
                                  episodeTitle: record.nextTitle, progress: 0, remainingMs: 0))
            }
            if out.count >= limit { break }
        }
        return out
    }
}
