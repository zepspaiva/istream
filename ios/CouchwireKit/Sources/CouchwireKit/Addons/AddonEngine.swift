import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The person's add-ons, asked from the phone. Written from Stremio's public add-on protocol documentation
// (github.com/Stremio/stremio-addon-sdk: docs/protocol.md and docs/api/), and from what Couchwire's screens need:
// rows for Home, a catalog's next page, search, a title's page, the streams for a video, and its subtitles.
//
// Every request goes to the add-ons that say they serve it, all at once; answers are used in the person's order of
// add-ons, and an add-on that fails or answers nonsense is left out rather than failing the rest.

/// A subtitle an add-on offers.
public struct SubtitleOption: Codable, Hashable, Sendable {
    public let lang: String
    public let url: String
    /// For the deaf and hard of hearing (sound descriptions as well as speech).
    public let sdh: Bool
    /// The add-on's name.
    public let addon: String
}

/// A problem worth telling the person about, in words they can act on.
public struct AddonError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

public actor AddonEngine {
    private let session: URLSession
    private var manifests: [AddonURL: Manifest] = [:]

    public init(session: URLSession = AddonEngine.defaultSession) {
        self.session = session
    }

    /// Add-ons are small web servers, some of them slow: no caching of our own, and a limit on waiting.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: configuration)
    }()

    // MARK: Add-ons

    /// The add-on's manifest; `fresh` asks again rather than using the one already read.
    public func manifest(_ url: AddonURL, fresh: Bool = false) async throws -> Manifest {
        if !fresh, let known = manifests[url] { return known }
        let json = try await get(url.manifest)
        guard let manifest = Manifest(json: json) else {
            throw AddonError(message: "That address answered, but not with an add-on.")
        }
        manifests[url] = manifest
        return manifest
    }

    /// The add-ons whose manifest could be read, in the order given.
    public func load(_ urls: [AddonURL]) async -> [InstalledAddon] {
        var found: [Int: InstalledAddon] = [:]
        await withTaskGroup(of: (Int, InstalledAddon?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let manifest = try? await self.manifest(url)
                    return (index, manifest.map { InstalledAddon(url: url, manifest: $0) })
                }
            }
            for await (index, addon) in group {
                found[index] = addon
            }
        }
        return urls.indices.compactMap { found[$0] }
    }

    // MARK: Browsing

    /// Home's rows: the first page of each catalog that can be listed as it is (no search or other value needed),
    /// add-on by add-on in the person's order, up to `limit` rows. `hidden` holds row ids to leave out.
    public func homeRows(_ addons: [InstalledAddon], limit: Int = 8, hidden: Set<String> = []) async -> [Row] {
        var feeds: [(addon: InstalledAddon, catalog: CatalogDef)] = []
        for addon in addons {
            for catalog in addon.manifest.catalogs where catalog.isFeed && MediaType(rawValue: catalog.type) != nil {
                guard !hidden.contains(Self.rowId(addon, catalog)) else { continue }
                feeds.append((addon, catalog))
            }
        }
        // A few spare ones, for catalogs that turn out empty or don't answer.
        let asked = Array(feeds.prefix(limit + 4))
        let rows: [Row?] = await inOrder(asked) { feed in
            guard let items = try? await self.catalog(feed.addon, feed.catalog), !items.isEmpty else { return nil }
            return Row(addon: feed.addon.id, addonName: feed.addon.name, type: feed.catalog.type,
                       catalog: feed.catalog.id, title: Self.rowTitle(feed.catalog), items: items)
        }
        return Array(rows.compactMap { $0 }.prefix(limit))
    }

    /// One catalog's page (`skip` titles in), optionally of a genre or for a search.
    public func catalog(_ addon: InstalledAddon, _ catalog: CatalogDef, skip: Int = 0, genre: String? = nil,
                        search: String? = nil) async throws -> [Card] {
        var extra: [(String, String)] = []
        if let search { extra.append(("search", search)) }
        if let genre { extra.append(("genre", genre)) }
        if skip > 0 { extra.append(("skip", String(skip))) }
        let address = Self.address(addon, "catalog", type: catalog.type, id: catalog.id, extra: extra)
        guard let json = try await get(address) as? JSONObject else {
            throw AddonError(message: "\(addon.name) sent something that isn't a list of titles.")
        }
        var seen = Set<String>()
        return json.objects("metas").compactMap { Self.card($0, type: catalog.type) }
            .filter { seen.insert($0.id).inserted }
    }

    /// The next page of a Home row.
    public func more(_ row: Row, in addons: [InstalledAddon], skip: Int) async throws -> [Card] {
        guard let addon = addons.first(where: { $0.id == row.addon }),
              let catalog = addon.manifest.catalogs.first(where: { $0.type == row.type && $0.id == row.catalog })
        else { throw AddonError(message: "The add-on with this list isn't installed any more.") }
        return try await self.catalog(addon, catalog, skip: skip)
    }

    /// Search across every catalog that can search, movies and series apart, without repeats.
    public func search(_ term: String, in addons: [InstalledAddon]) async -> SearchResults {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return SearchResults(movies: [], series: []) }
        var searchable: [(addon: InstalledAddon, catalog: CatalogDef)] = []
        for addon in addons {
            for catalog in addon.manifest.catalogs
            where catalog.supports("search") && MediaType(rawValue: catalog.type) != nil {
                searchable.append((addon, catalog))
            }
        }
        let pages: [(type: String, cards: [Card])?] = await inOrder(searchable) { entry in
            guard let cards = try? await self.catalog(entry.addon, entry.catalog, search: term) else { return nil }
            return (entry.catalog.type, cards)
        }
        var movies: [Card] = []
        var series: [Card] = []
        var seen = Set<String>()
        for page in pages.compactMap({ $0 }) {
            for card in page.cards where seen.insert("\(card.type.rawValue)/\(card.id)").inserted {
                if card.type == .movie { movies.append(card) } else { series.append(card) }
            }
        }
        return SearchResults(movies: movies, series: series)
    }

    /// A title's page. The first add-on (in the person's order) that answers for this very id wins; when none does,
    /// the first answer at all, since add-ons can know a title under another id.
    public func title(_ type: MediaType, _ id: String, in addons: [InstalledAddon]) async -> Title? {
        let serving = addons.filter { $0.manifest.serves("meta", type: type.rawValue, id: id) }
        let answers: [Title?] = await inOrder(serving) { addon in
            let address = Self.address(addon, "meta", type: type.rawValue, id: id)
            guard let json = try? await self.get(address) as? JSONObject else { return nil }
            // The meta is an object; some add-ons wrap it in a list.
            guard let meta = json.object("meta") ?? json.objects("meta").first else { return nil }
            return Self.title(meta, type: type, fallbackId: id, addon: addon.name)
        }
        let titles = answers.compactMap { $0 }
        return titles.first { $0.id == id } ?? titles.first
    }

    /// The streams the TV can open, in the add-ons' order, and the one Play would start (see `StreamDetails.best`).
    public func streams(_ type: MediaType, videoId: String, in addons: [InstalledAddon], quality: String = "auto")
        async -> (streams: [StreamOption], best: StreamOption?) {
        let serving = addons.filter { $0.manifest.serves("stream", type: type.rawValue, id: videoId) }
        let lists: [[StreamOption]?] = await inOrder(serving) { addon in
            let address = Self.address(addon, "stream", type: type.rawValue, id: videoId)
            guard let json = try? await self.get(address) as? JSONObject else { return nil }
            return json.objects("streams").compactMap { StreamDetails.option(from: $0, addon: addon.name) }
        }
        var seen = Set<String>()
        let streams = lists.compactMap { $0 }.joined().filter { seen.insert($0.url).inserted }
        return (streams, StreamDetails.best(streams, quality: quality))
    }

    /// The subtitles on offer for a video, each file once. `forTV` keeps the list short enough for the TV's menu:
    /// at most 3 per language and 40 in all.
    public func subtitles(_ type: MediaType, videoId: String, in addons: [InstalledAddon], forTV: Bool = false)
        async -> [SubtitleOption] {
        let serving = addons.filter { $0.manifest.serves("subtitles", type: type.rawValue, id: videoId) }
        let lists: [[SubtitleOption]?] = await inOrder(serving) { addon in
            let address = Self.address(addon, "subtitles", type: type.rawValue, id: videoId)
            guard let json = try? await self.get(address) as? JSONObject else { return nil }
            return json.objects("subtitles").compactMap { Self.subtitle($0, addon: addon.name) }
        }
        var seen = Set<String>()
        let all = lists.compactMap { $0 }.joined().filter { seen.insert($0.url).inserted }
        guard forTV else { return Array(all) }
        var perLanguage: [String: Int] = [:]
        var kept: [SubtitleOption] = []
        for subtitle in all where kept.count < 40 {
            let key = subtitle.lang.lowercased()
            guard perLanguage[key, default: 0] < 3 else { continue }
            perLanguage[key, default: 0] += 1
            kept.append(subtitle)
        }
        return kept
    }

    // MARK: Requests

    /// Runs `work` for every item at once and gives the answers back in the items' order.
    private func inOrder<Item, Answer: Sendable>(_ items: [Item], _ work: @escaping @Sendable (Item) async -> Answer?)
        async -> [Answer?] {
        var answers = [Answer?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Answer?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await work(item)) }
            }
            for await (index, answer) in group {
                answers[index] = answer
            }
        }
        return answers
    }

    /// The JSON at an address.
    private nonisolated func get(_ address: String) async throws -> Any {
        guard let url = URL(string: address) else { throw AddonError(message: "That isn't a web address.") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AddonError(message: "Couldn't reach \(url.host ?? "the add-on"): \(error.localizedDescription)")
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw AddonError(message: "\(url.host ?? "The add-on") answered with an error (\(status)).")
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AddonError(message: "\(url.host ?? "The add-on") didn't answer with JSON.")
        }
    }

    /// `<base>/<resource>/<type>/<id>[/<extra>].json`, where extra is `name=value` pairs joined by `&`.
    static func address(_ addon: InstalledAddon, _ resource: String, type: String, id: String,
                        extra: [(String, String)] = []) -> String {
        var address = addon.url.base + "/" + resource + "/" + segment(type) + "/" + segment(id)
        if !extra.isEmpty {
            address += "/" + extra.map { "\(component($0.0))=\(component($0.1))" }.joined(separator: "&")
        }
        return address + ".json"
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")

    /// A path part: ids keep their colons (`tt0386676:2:3`).
    private static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: ":"))) ?? text
    }

    /// A value in the extra part: everything but letters, digits and `-_.~` escaped.
    private static func component(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    // MARK: Reading answers

    static func rowId(_ addon: InstalledAddon, _ catalog: CatalogDef) -> String {
        "\(addon.id)/\(catalog.type)/\(catalog.id)"
    }

    /// "Popular" becomes "Popular movies"; names that already say what they hold stay as they are.
    static func rowTitle(_ catalog: CatalogDef) -> String {
        let name = catalog.name ?? catalog.id
        let lower = name.lowercased()
        if ["movie", "film", "series", "show", "tv"].contains(where: { lower.contains($0) }) { return name }
        return name + (catalog.type == "movie" ? " movies" : " series")
    }

    /// A title on a list (a meta preview). Needs an id and a name; the type falls back to the catalog's.
    static func card(_ meta: JSONObject, type fallback: String) -> Card? {
        guard let id = meta.text("id"), let name = meta.text("name"),
              let type = MediaType(rawValue: meta.text("type") ?? fallback) else { return nil }
        return Card(id: id, type: type, name: name, poster: meta.text("poster"), posterShape: meta.text("posterShape"),
                    background: meta.text("background"), logo: meta.text("logo"), year: year(meta),
                    rating: meta.text("imdbRating"), description: meta.text("description"))
    }

    /// `releaseInfo` ("1994", "2005-2013"), else the year of `released`.
    static func year(_ meta: JSONObject) -> String? {
        if let info = meta.text("releaseInfo") { return info }
        if let released = meta.text("released"), released.count >= 4, Int(released.prefix(4)) != nil {
            return String(released.prefix(4))
        }
        return nil
    }

    /// Names from a plain list, else from the meta's links of that category.
    static func names(_ meta: JSONObject, keys: [String], linkCategories: [String]) -> [String] {
        for key in keys {
            let list = meta.texts(key)
            if !list.isEmpty { return list }
        }
        return meta.objects("links").compactMap { link in
            guard let category = link.text("category")?.lowercased(), linkCategories.contains(category) else { return nil }
            return link.text("name")
        }
    }

    static func title(_ meta: JSONObject, type: MediaType, fallbackId: String, addon: String) -> Title? {
        guard let name = meta.text("name") else { return nil }
        let id = meta.text("id") ?? fallbackId
        var videos: [Video] = []
        if type == .series {
            videos = meta.objects("videos").compactMap { video -> Video? in
                guard let videoId = video.text("id") else { return nil }
                return Video(id: videoId, season: Int(video.number("season") ?? 0),
                             episode: Int(video.number("episode") ?? video.number("number") ?? 0),
                             title: video.text("title") ?? video.text("name"),
                             overview: video.text("overview") ?? video.text("description"),
                             thumbnail: video.text("thumbnail"), released: video.text("released"),
                             progress: 0, watched: false)
            }
            videos = videos.enumerated()
                .sorted { ($0.element.season, $0.element.episode, $0.offset) < ($1.element.season, $1.element.episode, $1.offset) }
                .map(\.element)
        }
        let trailers = meta.objects("trailers")
        let trailer = (trailers.first { $0.text("type")?.lowercased() == "trailer" } ?? trailers.first)?.text("source")
        return Title(id: id, type: type, name: name, poster: meta.text("poster"), background: meta.text("background"),
                     logo: meta.text("logo"), year: year(meta), rating: meta.text("imdbRating"),
                     description: meta.text("description"), addonName: addon, runtime: meta.text("runtime"),
                     released: meta.text("released"), country: meta.text("country"),
                     genres: names(meta, keys: ["genres", "genre"], linkCategories: ["genre", "genres"]),
                     cast: names(meta, keys: ["cast"], linkCategories: ["cast", "actor", "actors"]),
                     director: names(meta, keys: ["director", "directors"], linkCategories: ["director", "directors"]),
                     certification: meta.text("certification"), status: meta.text("status"), trailer: trailer,
                     inLibrary: false, progress: nil, videos: videos)
    }

    private static let hearingImpaired = try! NSRegularExpression(
        pattern: #"(\bsdh\b|\[cc\]|\bcc\b|hearing[ -]impaired)"#, options: [.caseInsensitive])

    static func subtitle(_ json: JSONObject, addon: String) -> SubtitleOption? {
        guard let url = json.text("url"), url.lowercased().hasPrefix("http") else { return nil }
        let words = [json.text("label"), json.text("id")].compactMap { $0 }.joined(separator: " ")
        let sdh = hearingImpaired.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)) != nil
        return SubtitleOption(lang: json.text("lang") ?? "und", url: url, sdh: sdh, addon: addon)
    }
}

extension Title {
    /// The same title with the person's own state: whether it's in their library, and how far they got in each
    /// video (keyed by video id; a movie's own entry is under its id, or the id it was opened with).
    public func with(inLibrary: Bool, progress: [String: (fraction: Double, watched: Bool)]) -> Title {
        let videos = self.videos.map { video in
            guard let entry = progress[video.id] else { return video }
            return Video(id: video.id, season: video.season, episode: video.episode, title: video.title,
                         overview: video.overview, thumbnail: video.thumbnail, released: video.released,
                         progress: entry.fraction, watched: entry.watched)
        }
        var own = self.progress
        if type == .movie, let entry = progress[id] ?? progress.values.first {
            own = entry.fraction
        }
        return Title(id: id, type: type, name: name, poster: poster, background: background, logo: logo, year: year,
                     rating: rating, description: description, addonName: addonName, runtime: runtime,
                     released: released, country: country, genres: genres, cast: cast, director: director,
                     certification: certification, status: status, trailer: trailer, inLibrary: inLibrary,
                     progress: own, videos: videos)
    }
}
