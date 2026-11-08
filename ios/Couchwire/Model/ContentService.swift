import CouchwireKit
import Foundation

/// What the screens ask for (home, a catalog, search, a title, streams, the library), answered on the phone: the
/// person's add-ons through `AddonEngine`, and their library and progress from `LocalStore`. It replaces the Pi's API of M1 to M3
/// with the same calls.
@MainActor
final class ContentService {
    let store: LocalStore
    let engine = AddonEngine()
    private var installed: [InstalledAddon]?
    private var installedFor: [AddonURL] = []

    /// Which quality Play picks ("auto" keeps the add-ons' order).
    var preferredQuality = "auto"

    init(store: LocalStore) {
        self.store = store
    }

    /// The person's add-ons, their manifests loaded (again when the list changed).
    func addons() async -> [InstalledAddon] {
        let urls = store.addonURLs
        if let installed, urls == installedFor { return installed }
        let loaded = await engine.load(urls)
        installed = loaded
        installedFor = urls
        return loaded
    }

    func addonsChanged() {
        installed = nil
    }

    // MARK: Browsing

    func home() async throws -> Home {
        let addons = await addons()
        let rows = await engine.homeRows(addons)
        // nil: there are add-ons, and none of them answered.
        let unreachable = !store.addonURLs.isEmpty && addons.isEmpty
        return Home(continueWatching: store.continueWatching(), rows: unreachable ? nil : rows)
    }

    func catalog(_ row: Row, skip: Int) async throws -> [Card] {
        try await engine.more(row, in: await addons(), skip: skip)
    }

    func search(_ text: String) async throws -> SearchResults {
        await engine.search(text, in: await addons())
    }

    func title(_ type: MediaType, _ id: String) async throws -> Title {
        guard let title = await engine.title(type, id, in: await addons()) else {
            throw AddonError(message: "None of your add-ons knows this title")
        }
        var progress: [String: (fraction: Double, watched: Bool)] = [:]
        for record in store.progress(for: title.id) + (title.id == id ? [] : store.progress(for: id)) {
            progress[record.videoId] = (record.fraction, record.finished)
        }
        return title.with(inLibrary: store.isInLibrary(title.id) || store.isInLibrary(id), progress: progress)
    }

    func streams(_ type: MediaType, videoId: String) async throws -> Streams {
        let found = await engine.streams(type, videoId: videoId, in: await addons(), quality: preferredQuality)
        return Streams(best: found.best?.url, streams: found.streams)
    }

    // MARK: Library

    func library() async throws -> [Card] {
        store.library().map(\.card)
    }

    func addToLibrary(_ card: Card) async throws {
        store.addToLibrary(card)
    }

    func removeFromLibrary(_ type: MediaType, _ id: String) async throws {
        store.removeFromLibrary(id)
    }

    // MARK: Playing

    /// What Free My TV needs to play a movie or an episode (the play message's params): the stream (the chosen one,
    /// else the best), the title's details for its start screen, the subtitles with their addresses, and what the
    /// phone knows the video as.
    func playParams(_ type: MediaType, videoId: String, streamUrl: String? = nil) async throws -> (params: Data, title: String, label: String) {
        let addons = await addons()
        let parts = videoId.split(separator: ":")
        let isEpisode = type == .series && parts.count >= 3
        let contentId = isEpisode ? parts.dropLast(2).joined(separator: ":") : videoId
        let season = isEpisode ? Int(parts[parts.count - 2]) : nil
        let episode = isEpisode ? Int(parts[parts.count - 1]) : nil

        async let titleTask = engine.title(type, contentId, in: addons)
        async let subtitlesTask = engine.subtitles(type, videoId: videoId, in: addons, forTV: true)
        let found = await engine.streams(type, videoId: videoId, in: addons, quality: preferredQuality)
        let stream = streamUrl.flatMap { url in found.streams.first { $0.url == url } } ?? found.best
        guard let url = stream?.url ?? streamUrl else {
            throw AddonError(message: "None of your add-ons has a stream the TV can play for this")
        }
        let title = await titleTask
        let subtitles = await subtitlesTask
        let video = title?.videos.first { $0.id == videoId }
        let name = title?.name ?? contentId
        var meta: [String: Any] = ["show": name]
        meta["season"] = season
        meta["episode"] = episode
        meta["episodeTitle"] = video?.title
        meta["description"] = video?.overview ?? title?.description
        meta["backdrop"] = title?.background
        meta["logo"] = title?.logo
        meta["year"] = title?.year
        meta["runtime"] = title?.runtime
        meta["country"] = title?.country
        var params: [String: Any] = [
            "url": url, "title": name, "label": stream?.label ?? "", "meta": meta,
            "subtitles": subtitles.map { ["lang": $0.lang, "url": $0.url, "sdh": $0.sdh, "addon": $0.addon] as [String: Any] },
            "session": ["type": type.rawValue, "contentId": contentId, "videoId": videoId],
        ]
        params["poster"] = title?.poster ?? title?.background
        return (try JSONSerialization.data(withJSONObject: params), name, stream?.label ?? "")
    }

    /// Where the TV got to, kept for Continue watching and the title page; a finished episode looks up the next one.
    func saveProgress(_ state: PlayerState) {
        guard let ref = state.ref else { return }
        let type = ref.type ?? (state.season != nil ? "series" : "movie")
        let record = store.progressRecord(contentId: ref.contentId, type: type, videoId: ref.videoId)
        record.position = state.position
        record.duration = state.duration
        record.updatedAt = Date()
        record.season = state.season
        record.episode = state.episode
        record.episodeTitle = state.episodeTitle
        record.name = state.name
        record.poster = state.poster ?? record.poster
        record.background = state.backdrop ?? record.background
        store.save()
        if record.finished, type == "series", record.nextVideoId == nil {
            Task { await findNext(after: record) }
        }
    }

    private func findNext(after record: WatchProgress) async {
        guard let title = await engine.title(.series, record.contentId, in: await addons()),
              let index = title.videos.firstIndex(where: { $0.id == record.videoId }) else { return }
        let next = title.videos[(index + 1)...].first { $0.season > 0 && $0.hasAired }
        record.nextVideoId = next?.id
        record.nextSeason = next?.season
        record.nextEpisode = next?.episode
        record.nextTitle = next?.title
        store.save()
    }

    /// For the TV's own subtitle request: the file's lines.
    func cues(_ url: String) async -> [Cue] {
        guard let address = URL(string: url) else { return [] }
        return (try? await SubtitleReader.cues(from: address)) ?? []
    }
}
