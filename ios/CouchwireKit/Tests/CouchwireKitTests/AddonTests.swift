import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CouchwireKit

// The add-on engine against made-up add-ons, shaped like the examples in Stremio's add-on protocol docs.

// MARK: Addresses

@Test func addonAddressesAsPeoplePasteThem() {
    #expect(AddonURL("https://v3-cinemeta.strem.io/manifest.json")?.base == "https://v3-cinemeta.strem.io")
    #expect(AddonURL(" https://addon.example.com/abc%3D/manifest.json/ ")?.base == "https://addon.example.com/abc%3D")
    #expect(AddonURL("stremio://addon.example.com/conf/manifest.json")?.base == "https://addon.example.com/conf")
    #expect(AddonURL("addon.example.com")?.base == "https://addon.example.com")
    #expect(AddonURL("http://192.168.1.20:7000/manifest.json")?.base == "http://192.168.1.20:7000")
    #expect(AddonURL("HTTPS://addon.example.com/Manifest.json")?.manifest == "https://addon.example.com/manifest.json")
    #expect(AddonURL("hello") == nil)
    #expect(AddonURL("") == nil)
    #expect(AddonURL("ftp://addon.example.com/manifest.json") == nil)
}

@Test func savedAddressesReadBackTheSame() {
    for raw in ["https://a.example.com/manifest.json", "https://a.example.com/x/y%20z/manifest.json"] {
        let url = AddonURL(raw)!
        #expect(AddonURL(url.base) == url)
    }
}

@Test func requestAddresses() {
    let addon = InstalledAddon(url: AddonURL("https://a.example.com/cfg")!, manifest: Manifest(json: ["id": "a"])!)
    #expect(AddonEngine.address(addon, "stream", type: "series", id: "tt0386676:2:3")
        == "https://a.example.com/cfg/stream/series/tt0386676:2:3.json")
    #expect(AddonEngine.address(addon, "catalog", type: "movie", id: "top",
                                extra: [("search", "the office & co"), ("skip", "100")])
        == "https://a.example.com/cfg/catalog/movie/top/search=the%20office%20%26%20co&skip=100.json")
}

// MARK: Manifests

private let exampleManifest: [String: Any] = [
    "id": "org.example.addon", "version": "1.2.0", "name": "Example", "description": "Example add-on",
    "types": ["movie", "series"], "idPrefixes": ["tt"],
    "resources": ["catalog", "meta", ["name": "stream", "types": ["movie"], "idPrefixes": ["tt", "ex:"]],
                  ["name": "subtitles", "types": ["movie", "series"]]],
    "catalogs": [
        ["type": "movie", "id": "top", "name": "Popular",
         "extra": [["name": "genre", "options": ["Action", "Drama"]], ["name": "skip"]]],
        ["type": "series", "id": "find", "name": "Search", "extra": [["name": "search", "isRequired": true]]],
        ["type": "movie", "id": "old", "extraSupported": ["search"], "extraRequired": []],
        ["id": "no-type"],
    ],
    "behaviorHints": ["configurable": true, "configurationRequired": true],
]

@Test func readsAManifest() throws {
    let manifest = try #require(Manifest(json: exampleManifest))
    #expect(manifest.id == "org.example.addon")
    #expect(manifest.version == "1.2.0")
    #expect(manifest.resources.map(\.name) == ["catalog", "meta", "stream", "subtitles"])
    #expect(manifest.configurationRequired)
    #expect(manifest.catalogs.map(\.id) == ["top", "find", "old"])
    let top = manifest.catalogs[0]
    #expect(top.genres == ["Action", "Drama"])
    #expect(top.supports("skip") && !top.supports("search"))
    #expect(top.isFeed)
    #expect(manifest.catalogs[1].required == ["search"] && !manifest.catalogs[1].isFeed)
    #expect(manifest.catalogs[2].supports("search"))
    #expect(Manifest(json: ["name": "No id"]) == nil)
    #expect(Manifest(json: "nonsense") == nil)
}

@Test func whichRequestsAnAddonServes() throws {
    let manifest = try #require(Manifest(json: exampleManifest))
    // A plain name: the manifest's types and prefixes.
    #expect(manifest.serves("meta", type: "series", id: "tt0386676"))
    #expect(!manifest.serves("meta", type: "series", id: "kitsu:1"))
    #expect(!manifest.serves("meta", type: "channel", id: "tt1"))
    // In full: its own.
    #expect(manifest.serves("stream", type: "movie", id: "ex:42"))
    #expect(!manifest.serves("stream", type: "series", id: "tt0386676:1:1"))
    // In full without prefixes: every id.
    #expect(manifest.serves("subtitles", type: "series", id: "kitsu:1:2"))
    #expect(!manifest.serves("addon_catalog", type: "movie", id: "tt1"))
}

// MARK: Streams

@Test func describesAStream() throws {
    let option = try #require(StreamDetails.option(from: [
        "url": "https://cdn.example.com/v.mkv", "name": "Example\n2160p",
        "description": "Big Buck Bunny\nHDR10+ HEVC DDP5.1 Atmos\n🇬🇧 🇪🇸 · 4.2 GB",
        "behaviorHints": ["filename": "big.buck.bunny.mkv"],
    ], addon: "Example"))
    #expect(option.quality == "4K")
    #expect(option.hdr == "HDR10+")
    #expect(option.videoCodec == "HEVC")
    #expect(option.audioCodec == "DD+")
    #expect(option.size == "4.2 GB")
    #expect(option.languages == ["English", "Spanish"])
    #expect(option.title == "Big Buck Bunny · HDR10+ HEVC DDP5.1 Atmos · 🇬🇧 🇪🇸 · 4.2 GB")
    #expect(option.label == "4K HDR10+ · 4.2 GB")
    #expect(option.filename == "big.buck.bunny.mkv")
}

@Test func sizeFromTheHintWins() throws {
    let option = try #require(StreamDetails.option(from: [
        "url": "http://cdn.example.com/v.mp4", "title": "720p · 900 MB", "behaviorHints": ["videoSize": 1_500_000_000],
    ], addon: "Example"))
    #expect(option.size == "1.5 GB")
    #expect(option.quality == "720p")
    let plain = try #require(StreamDetails.option(from: ["url": "https://x.example/v.mp4"], addon: "Example"))
    #expect(plain.label == "Example" && plain.title == "Example")
}

@Test func leavesOutStreamsTheTVCantOpen() {
    #expect(StreamDetails.option(from: ["ytId": "abc"], addon: "A") == nil)
    #expect(StreamDetails.option(from: ["externalUrl": "https://example.com"], addon: "A") == nil)
    #expect(StreamDetails.option(from: ["url": "rtmp://x.example/live"], addon: "A") == nil)
    #expect(StreamDetails.option(from: [
        "url": "https://x.example/v.mp4",
        "behaviorHints": ["notWebReady": true, "proxyHeaders": ["request": ["User-Agent": "X"]]],
    ], addon: "A") == nil)
    #expect(StreamDetails.option(from: ["url": "https://x.example/v.mkv", "behaviorHints": ["notWebReady": true]],
                                 addon: "A") != nil)
}

private func stream(_ url: String, _ text: String) -> StreamOption {
    StreamDetails.option(from: ["url": url, "name": text], addon: "A")!
}

@Test func playPicksAStream() {
    let streams = [
        stream("https://x.example/1", "2160p DTS-HD"),
        stream("https://x.example/2", "1080p TrueHD"),
        stream("https://x.example/3", "720p AAC"),
        stream("https://x.example/4", "1080p DD5.1"),
        stream("https://x.example/5", "2160p EAC3"),
    ]
    #expect(StreamDetails.best(streams, quality: "auto")?.url == "https://x.example/3")
    #expect(StreamDetails.best(streams, quality: "4K")?.url == "https://x.example/5")
    #expect(StreamDetails.best(streams, quality: "1080p")?.url == "https://x.example/4")
    #expect(StreamDetails.best(Array(streams.prefix(3)), quality: "1080p")?.url == "https://x.example/3")
    // Only streams whose sound may not play: still one of them.
    #expect(StreamDetails.best([streams[0]], quality: "auto")?.url == "https://x.example/1")
    #expect(StreamDetails.best([], quality: "auto") == nil)
}

// MARK: The engine against made-up add-ons

/// Answers requests from a table of address → JSON text, for the tests' own add-on hosts.
final class FakeAddons: URLProtocol {
    nonisolated(unsafe) static var answers: [String: String] = [:]
    static let lock = NSLock()

    static func serve(_ table: [String: String]) {
        lock.lock()
        answers.merge(table) { $1 }
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let address = request.url?.absoluteString ?? ""
        Self.lock.lock()
        let body = Self.answers[address]
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var engine: AddonEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeAddons.self]
        return AddonEngine(session: URLSession(configuration: configuration))
    }
}

private func setUpAddons() {
    FakeAddons.serve([
        "https://meta.test/manifest.json": """
        {"id":"test.meta","version":"1.0.0","name":"Meta","types":["movie","series"],"idPrefixes":["tt"],
         "resources":["catalog","meta"],
         "catalogs":[{"type":"movie","id":"top","name":"Popular","extra":[{"name":"search"},{"name":"skip"}]},
                     {"type":"series","id":"top","name":"Popular","extra":[{"name":"search"}]},
                     {"type":"tv","id":"live","name":"Channels"}]}
        """,
        "https://meta.test/catalog/movie/top.json": """
        {"metas":[{"id":"tt1254207","type":"movie","name":"Big Buck Bunny","poster":"https://img.test/p.jpg",
                   "releaseInfo":"2008","imdbRating":"6.4"},
                  {"id":"tt1254207","type":"movie","name":"Big Buck Bunny (again)"},
                  {"type":"movie","name":"No id"}]}
        """,
        "https://meta.test/catalog/series/top.json": #"{"metas":[]}"#,
        "https://meta.test/catalog/movie/top/skip=100.json": #"{"metas":[{"id":"tt2","type":"movie","name":"Two"}]}"#,
        "https://meta.test/catalog/movie/top/search=bunny.json":
            #"{"metas":[{"id":"tt1254207","type":"movie","name":"Big Buck Bunny"}]}"#,
        "https://meta.test/catalog/series/top/search=bunny.json":
            #"{"metas":[{"id":"tt9","type":"series","name":"Bunny Show"}]}"#,
        "https://meta.test/meta/series/tt9.json": """
        {"meta":{"id":"tt9","type":"series","name":"Bunny Show","releaseInfo":"2001-2003","genres":["Comedy"],
                 "links":[{"name":"Ann Actor","category":"Cast","url":"stremio:///search?search=Ann"}],
                 "videos":[{"id":"tt9:2:1","title":"Back","season":2,"episode":1},
                           {"id":"tt9:1:2","title":"Second","season":1,"episode":2,"released":"2001-01-08T00:00:00.000Z"},
                           {"id":"tt9:1:1","title":"Pilot","season":1,"episode":1},
                           {"id":"tt9:0:1","title":"Special","season":0,"episode":1},
                           {"title":"No id","season":1,"episode":3}]}}
        """,
        "https://other.test/manifest.json": """
        {"id":"test.other","version":"1.0.0","name":"Other","types":["movie","series"],
         "resources":[{"name":"meta","types":["series"],"idPrefixes":["tt"]},
                      {"name":"stream","types":["movie","series"],"idPrefixes":["tt"]},"subtitles"],
         "catalogs":[]}
        """,
        "https://other.test/meta/series/tt9.json": #"{"meta":{"id":"tt9","type":"series","name":"Bunny Show (other)"}}"#,
        "https://other.test/stream/movie/tt1254207.json": """
        {"streams":[{"url":"https://cdn.test/bbb-2160.mp4","name":"Other 4K","description":"2160p DTS"},
                    {"url":"https://cdn.test/bbb-1080.mp4","name":"Other","description":"1080p AAC"},
                    {"infoHash":"0000000000000000000000000000000000000000"},
                    {"url":"https://cdn.test/bbb-1080.mp4","name":"Repeat"}]}
        """,
        "https://other.test/subtitles/movie/tt1254207.json": """
        {"subtitles":[{"id":"1","url":"https://subs.test/en1.srt","lang":"eng"},
                      {"id":"2","url":"https://subs.test/en2.srt","lang":"eng","label":"English [CC]"},
                      {"id":"3","url":"https://subs.test/en3.srt","lang":"eng"},
                      {"id":"4","url":"https://subs.test/en4.srt","lang":"eng"},
                      {"id":"5","url":"https://subs.test/es.srt","lang":"spa"},
                      {"id":"6","url":"https://subs.test/es.srt","lang":"spa"}]}
        """,
        "https://broken.test/manifest.json": "not json",
    ])
}

private func urls(_ raw: String...) -> [AddonURL] { raw.compactMap { AddonURL($0) } }

@Test func loadsAddonsInOrderSkippingBrokenOnes() async throws {
    setUpAddons()
    let engine = FakeAddons.engine
    let addons = await engine.load(urls("https://other.test", "https://broken.test", "https://missing.test",
                                        "https://meta.test"))
    #expect(addons.map(\.name) == ["Other", "Meta"])
    await #expect(throws: AddonError.self) { try await engine.manifest(AddonURL("https://broken.test")!) }
}

@Test func homeRowsAndMore() async throws {
    setUpAddons()
    let engine = FakeAddons.engine
    let addons = await engine.load(urls("https://meta.test"))
    let rows = await engine.homeRows(addons)
    // The series row is empty and the tv catalog isn't for movies or series: one row.
    #expect(rows.map(\.title) == ["Popular movies"])
    let row = try #require(rows.first)
    #expect(row.items.map(\.name) == ["Big Buck Bunny"])
    #expect(row.items.first?.year == "2008")
    #expect(row.items.first?.rating == "6.4")
    #expect(row.id == "https://meta.test/movie/top")
    #expect(try await engine.more(row, in: addons, skip: 100).map(\.id) == ["tt2"])
    #expect(await engine.homeRows(addons, hidden: [row.id]).isEmpty)
}

@Test func searchesMoviesAndSeries() async throws {
    setUpAddons()
    let engine = FakeAddons.engine
    let addons = await engine.load(urls("https://meta.test", "https://other.test"))
    let found = await engine.search(" bunny ", in: addons)
    #expect(found.movies.map(\.id) == ["tt1254207"])
    #expect(found.series.map(\.id) == ["tt9"])
    #expect(await engine.search("  ", in: addons).movies.isEmpty)
}

@Test func titlePageFromTheFirstAddonInOrder() async throws {
    setUpAddons()
    let engine = FakeAddons.engine
    let addons = await engine.load(urls("https://meta.test", "https://other.test"))
    let title = try #require(await engine.title(.series, "tt9", in: addons))
    #expect(title.name == "Bunny Show")
    #expect(title.addonName == "Meta")
    #expect(title.year == "2001-2003")
    #expect(title.genres == ["Comedy"])
    #expect(title.cast == ["Ann Actor"])
    #expect(title.videos.map(\.id) == ["tt9:0:1", "tt9:1:1", "tt9:1:2", "tt9:2:1"])
    #expect(title.seasons == [1, 2, 0])

    let reversed = await engine.load(urls("https://other.test", "https://meta.test"))
    #expect(await engine.title(.series, "tt9", in: reversed)?.name == "Bunny Show (other)")
    #expect(await engine.title(.movie, "tt404", in: addons) == nil)

    let mine = title.with(inLibrary: true, progress: ["tt9:1:1": (1, true), "tt9:1:2": (0.4, false)])
    #expect(mine.inLibrary)
    #expect(mine.nextEpisode?.id == "tt9:1:2")
}

@Test func streamsAndTheOnePlayStarts() async throws {
    setUpAddons()
    let engine = FakeAddons.engine
    let addons = await engine.load(urls("https://meta.test", "https://other.test"))
    let found = await engine.streams(.movie, videoId: "tt1254207", in: addons)
    #expect(found.streams.map(\.url) == ["https://cdn.test/bbb-2160.mp4", "https://cdn.test/bbb-1080.mp4"])
    #expect(found.best?.url == "https://cdn.test/bbb-1080.mp4")
    #expect(found.streams.first?.addon == "Other")
}

@Test func subtitlesForTheTV() async throws {
    setUpAddons()
    let engine = FakeAddons.engine
    let addons = await engine.load(urls("https://other.test"))
    let all = await engine.subtitles(.movie, videoId: "tt1254207", in: addons)
    #expect(all.count == 5)
    #expect(all.filter(\.sdh).map(\.url) == ["https://subs.test/en2.srt"])
    let forTV = await engine.subtitles(.movie, videoId: "tt1254207", in: addons, forTV: true)
    #expect(forTV.map(\.lang) == ["eng", "eng", "eng", "spa"])
}
