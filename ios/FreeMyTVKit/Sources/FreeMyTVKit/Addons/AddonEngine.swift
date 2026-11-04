import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A subtitle an add-on offers.
public struct SubtitleOption: Codable, Hashable, Sendable {
    public let lang: String
    public let url: String
    public let sdh: Bool
    public let addon: String
}

/// Something went wrong with an add-on: kept short, for people.
public struct AddonError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

/// The add-ons, from the phone: what the Pi's Nuvio Web fork did (catalogs, search, a title's details, streams,
/// subtitles), straight to each add-on. Manifests are kept for 30 minutes.
public actor AddonEngine {
    private let session: URLSession
    private var manifests: [String: (manifest: Manifest, at: Date)] = [:]
    private static let manifestTTL: TimeInterval = 30 * 60
    private static let timeout: TimeInterval = 15

    public init(session: URLSession = AddonEngine.defaultSession) {
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AddonEngine.timeout
        config.httpShouldSetCookies = false
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 64 << 20)
        return URLSession(configuration: config)
    }()

    // MARK: Add-ons

    /// What an add-on is (its manifest), for adding it or showing the list.
    public func manifest(_ url: AddonURL, fresh: Bool = false) async throws -> Manifest {
        if !fresh, let cached = manifests[url.base], Date().timeIntervalSince(cached.at) < Self.manifestTTL {
            return cached.manifest
        }
        let json = try await fetch(url.manifest)
        guard let manifest = Manifest(json: json) else {
            throw AddonError(message: "That address doesn't answer like an add-on")
        }
        manifests[url.base] = (manifest, Date())
        return manifest
    }

    /// The add-ons in this order, the ones that answer (the others are left out until they do).
    public func load(_ urls: [AddonURL]) async -> [InstalledAddon] {
        await withTaskGroup(of: (Int, InstalledAddon?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    let manifest = try? await self.manifest(url)
                    return (index, manifest.map { InstalledAddon(url: url, manifest: $0) })
                }
            }
            var found: [(Int, InstalledAddon)] = []
            for await (index, addon) in group {
                if let addon { found.append((index, addon)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: Browsing

    /// Home's rows: the first catalogs that need nothing extra, at most `limit`, each with its first page.
    public func homeRows(_ addons: [InstalledAddon], limit: Int = 8, hidden: Set<String> = []) async -> [Row] {
        var picks: [(InstalledAddon, CatalogDef)] = []
        for addon in addons {
            for catalog in addon.manifest.catalogs where catalog.required.isEmpty {
                if !hidden.contains("\(addon.manifest.id)/\(catalog.type)/\(catalog.id)") { picks.append((addon, catalog)) }
            }
        }
        picks = Array(picks.prefix(limit))
        let rows = await withTaskGroup(of: (Int, Row?).self) { group in
            for (index, pick) in picks.enumerated() {
                group.addTask {
                    let items = (try? await self.catalog(pick.0, pick.1)) ?? []
                    guard !items.isEmpty else { return (index, nil) }
                    return (index, Row(addon: pick.0.manifest.id, addonName: pick.0.manifest.name, type: pick.1.type,
                                       catalog: pick.1.id, title: pick.1.name ?? pick.0.manifest.name,
                                       items: Array(items.prefix(20))))
                }
            }
            var rows: [(Int, Row)] = []
            for await (index, row) in group {
                if let row { rows.append((index, row)) }
            }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return rows
    }

    /// One catalog's page (`skip` items in), optionally a genre or a search.
    public func catalog(_ addon: InstalledAddon, _ catalog: CatalogDef, skip: Int = 0, genre: String? = nil,
                        search: String? = nil) async throws -> [Card] {
        var extra: [(String, String)] = []
        if let search { extra.append(("search", search)) }
        if let genre { extra.append(("genre", genre)) }
        if skip > 0 { extra.append(("skip", String(skip))) }
        let json = try await request(addon, "catalog", type: catalog.type, id: catalog.id, extra: extra)
        var seen = Set<String>()
        return ((json as? JSON)?["metas"] as? [Any] ?? []).compactMap(Self.card).filter {
            seen.insert("\($0.type.rawValue):\($0.id)").inserted
        }
    }

    /// More of a home row.
    public func more(_ row: Row, in addons: [InstalledAddon], skip: Int) async throws -> [Card] {
        guard let addon = addons.first(where: { $0.manifest.id == row.addon }),
              let catalog = addon.manifest.catalogs.first(where: { $0.type == row.type && $0.id == row.catalog }) else {
            return []
        }
        return try await self.catalog(addon, catalog, skip: skip)
    }

    /// Every catalog that searches, together; each title once.
    public func search(_ term: String, in addons: [InstalledAddon]) async -> SearchResults {
        let searchable = addons.flatMap { addon in
            addon.manifest.catalogs.filter { $0.supports("search") }.map { (addon, $0) }
        }
        let batches = await withTaskGroup(of: (Int, [Card]).self) { group in
            for (index, pick) in searchable.enumerated() {
                group.addTask { (index, (try? await self.catalog(pick.0, pick.1, search: term)) ?? []) }
            }
            var batches: [(Int, [Card])] = []
            for await batch in group { batches.append(batch) }
            return batches.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen = Set<String>()
        let items = batches.filter { seen.insert("\($0.type.rawValue):\($0.id)").inserted }
        return SearchResults(movies: items.filter { $0.type == .movie }, series: items.filter { $0.type == .series })
    }

    /// A title's page: the first add-on (in the list's order) that knows it, and isn't describing another title.
    public func title(_ type: MediaType, _ id: String, in addons: [InstalledAddon]) async -> Title? {
        let providers = addons.filter { $0.manifest.serves("meta", type: type.rawValue, id: id) }
        let tasks = providers.map { addon in
            Task { try? await self.request(addon, "meta", type: type.rawValue, id: id) }
        }
        defer { tasks.forEach { $0.cancel() } }
        var fallback: Title?
        for (index, task) in tasks.enumerated() {
            guard let meta = (await task.value as? JSON)?["meta"] as? JSON else { continue }
            let title = Self.title(meta, type: type, requested: id, addonName: providers[index].manifest.name)
            if !Self.contradicts(meta, requested: id) { return title }
            fallback = fallback ?? title
        }
        return fallback
    }

    /// The streams the TV can open (a web link), in the add-ons' order, and the one Play would pick.
    public func streams(_ type: MediaType, videoId: String, in addons: [InstalledAddon], quality: String = "auto")
        async -> (streams: [StreamOption], best: StreamOption?) {
        let raw = await fanOut(addons, resource: "stream", type: type, id: videoId) { json, addon in
            ((json as? JSON)?["streams"] as? [Any] ?? []).compactMap { RawStream(json: $0, addonName: addon.name) }
        }.filter { $0.url != nil }
        return (raw.compactMap(\.option), pickPreferred(raw, quality: quality)?.option)
    }

    /// Every subtitle on offer, one per source; `forTV` keeps at most 3 per language and 40 in all.
    public func subtitles(_ type: MediaType, videoId: String, in addons: [InstalledAddon], forTV: Bool = false)
        async -> [SubtitleOption] {
        let sdh = try! NSRegularExpression(pattern: #"\b(sdh|cc|hi|hearing[- ]impaired)\b|\[cc\]"#,
                                           options: [.caseInsensitive])
        let all = await fanOut(addons, resource: "subtitles", type: type, id: videoId) { json, addon in
            ((json as? JSON)?["subtitles"] as? [Any] ?? []).compactMap { entry -> SubtitleOption? in
                guard let item = entry as? JSON, let url = string(item["url"]) else { return nil }
                let lang = string(item["lang"]) ?? "und"
                let label = "\(lang) \(string(item["id"]) ?? "")"
                let isSDH = sdh.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
                return SubtitleOption(lang: lang, url: url, sdh: isSDH, addon: addon.name)
            }
        }
        var seen = Set<String>()
        var perLanguage: [String: Int] = [:]
        var out: [SubtitleOption] = []
        for option in all where seen.insert(option.url).inserted {
            let count = perLanguage[option.lang, default: 0]
            if forTV && (count >= 3 || out.count >= 40) { continue }
            perLanguage[option.lang] = count + 1
            out.append(option)
        }
        return out
    }

    // MARK: Requests

    private func fanOut<T: Sendable>(_ addons: [InstalledAddon], resource: String, type: MediaType, id: String,
                                     map: @escaping @Sendable (Any, InstalledAddon) -> [T]) async -> [T] {
        let providers = addons.filter { $0.manifest.serves(resource, type: type.rawValue, id: id) }
        return await withTaskGroup(of: (Int, [T]).self) { group in
            for (index, addon) in providers.enumerated() {
                group.addTask {
                    guard let json = try? await self.request(addon, resource, type: type.rawValue, id: id) else {
                        return (index, [])
                    }
                    return (index, map(json, addon))
                }
            }
            var results: [(Int, [T])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    private func request(_ addon: InstalledAddon, _ resource: String, type: String, id: String,
                         extra: [(String, String)] = []) async throws -> Any {
        try await fetch(Self.resourceURL(addon.url.base, resource, type: type, id: id, extra: extra))
    }

    /// `<base>/<resource>/<type>/<id>[/<key=value&...>].json`, each part percent-encoded.
    static func resourceURL(_ base: String, _ resource: String, type: String, id: String,
                            extra: [(String, String)] = []) -> String {
        // As JavaScript's encodeURIComponent: ASCII letters and digits and -_.!~*'() stay, the rest is encoded.
        let unreserved = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        func encode(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
        }
        let path = "\(base)/\(resource)/\(encode(type))/\(encode(id))"
        let extras = extra.filter { !$0.1.isEmpty }.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return extras.isEmpty ? path + ".json" : "\(path)/\(extras).json"
    }

    private func fetch(_ address: String) async throws -> Any {
        guard let url = URL(string: address) else { throw AddonError(message: "Bad address") }
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AddonError(message: "The add-on said \(status)") }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Reading what add-ons send

    static func kind(_ type: Any?) -> MediaType { (type as? String) == "series" ? .series : .movie }

    static func rating(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return String(format: "%.1f", number.doubleValue) }
        return string(value)
    }

    static func card(_ json: Any) -> Card? {
        guard let meta = json as? JSON, let id = string(meta["id"]), let name = string(meta["name"]) else { return nil }
        return Card(id: id, type: kind(meta["type"]), name: name, poster: string(meta["poster"]),
                    posterShape: string(meta["posterShape"]), background: string(meta["background"]),
                    logo: string(meta["logo"]), year: string(meta["releaseInfo"]) ?? string(meta["year"]),
                    rating: rating(meta["imdbRating"]), description: string(meta["description"]))
    }

    static func people(_ meta: JSON, _ key: String, linkCategory: String) -> [String] {
        let direct = strings(meta[key])
        if !direct.isEmpty { return direct }
        var seen = Set<String>()
        return (meta["links"] as? [Any] ?? []).compactMap { $0 as? JSON }
            .filter { (string($0["category"]) ?? "").lowercased() == linkCategory.lowercased() }
            .compactMap { string($0["name"])?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func title(_ meta: JSON, type: MediaType, requested: String, addonName: String) -> Title {
        var seen = Set<String>()
        var seenEpisodes = Set<String>()
        let videos: [Video] = (meta["videos"] as? [Any] ?? []).compactMap { entry -> Video? in
            guard let video = entry as? JSON, let id = string(video["id"]), seen.insert(id).inserted,
                  let season = int(video["season"]), let episode = int(video["episode"]) ?? int(video["number"]),
                  seenEpisodes.insert("\(season):\(episode)").inserted else { return nil }
            return Video(id: id, season: season, episode: episode,
                         title: string(video["title"]) ?? string(video["name"]),
                         overview: string(video["overview"]) ?? string(video["description"]),
                         thumbnail: string(video["thumbnail"]),
                         released: string(video["released"]) ?? string(video["firstAired"]),
                         progress: 0, watched: false)
        }.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        let hints = meta["behaviorHints"] as? JSON
        let trailer = (meta["trailerStreams"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap { string($0["ytId"]) } }
            .first
        return Title(
            id: string(meta["id"]) ?? requested, type: type, name: string(meta["name"]) ?? requested,
            poster: string(meta["poster"]), background: string(meta["background"]), logo: string(meta["logo"]),
            year: string(meta["releaseInfo"]) ?? string(meta["year"]), rating: rating(meta["imdbRating"]),
            description: string(meta["description"]), addonName: addonName, runtime: string(meta["runtime"]),
            released: string(meta["released"]), country: string(meta["country"]), genres: strings(meta["genres"]),
            cast: people(meta, "cast", linkCategory: "Cast"),
            director: people(meta, "director", linkCategory: "Directors"),
            certification: string(meta["certification"]) ?? (hints?["adult"] as? Bool == true ? "18+" : nil),
            status: string(meta["status"]), trailer: trailer, inLibrary: false, progress: nil,
            videos: type == .series ? videos : [])
    }

    /// An add-on answering with another title's details (some return their best guess): an IMDb, TMDB or Kitsu id
    /// that doesn't match the one asked for.
    static func contradicts(_ meta: JSON, requested: String) -> Bool {
        func key(_ value: Any?) -> String? {
            guard let text = value as? String,
                  let match = text.range(of: #"^(tt\d+|(?:tmdb|kitsu):\d+)(?=:|$)"#, options: .regularExpression)
            else { return nil }
            return String(text[match])
        }
        func scheme(_ key: String) -> String { key.hasPrefix("tt") ? "tt" : String(key.prefix { $0 != ":" }) }
        guard let wanted = key(requested) else { return false }
        let keys = [meta["id"], meta["imdb_id"]].compactMap(key).filter { scheme($0) == scheme(wanted) }
        return !keys.isEmpty && !keys.contains(wanted)
    }
}

extension Title {
    /// The same title with this profile's library flag and how far each episode (or the movie) was watched.
    public func with(inLibrary: Bool, progress: [String: (fraction: Double, watched: Bool)]) -> Title {
        Title(id: id, type: type, name: name, poster: poster, background: background, logo: logo, year: year,
              rating: rating, description: description, addonName: addonName, runtime: runtime, released: released,
              country: country, genres: genres, cast: cast, director: director, certification: certification,
              status: status, trailer: trailer, inLibrary: inLibrary,
              progress: type == .movie ? progress[id]?.fraction : nil,
              videos: videos.map { video in
                  Video(id: video.id, season: video.season, episode: video.episode, title: video.title,
                        overview: video.overview, thumbnail: video.thumbnail, released: video.released,
                        progress: progress[video.id]?.fraction ?? 0, watched: progress[video.id]?.watched ?? false)
              })
    }
}
