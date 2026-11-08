import Foundation
import Testing
@testable import CouchwireKit

// The add-on engine's reading of what add-ons send, from fixtures (no network).

private func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }

@Test func addonAddressesAsPeoplePasteThem() {
    #expect(AddonURL("https://v3-cinemeta.strem.io/manifest.json")?.base == "https://v3-cinemeta.strem.io")
    #expect(AddonURL("stremio://torrentio.strem.fun/abc/manifest.json")?.base == "https://torrentio.strem.fun/abc")
    #expect(AddonURL("https://x.example/a/")?.manifest == "https://x.example/a/manifest.json")
    #expect(AddonURL("not a url") == nil)
}

@Test func readsAManifest() throws {
    let manifest = try #require(Manifest(json: json("""
    {"id":"com.linvo.cinemeta","name":"Cinemeta","version":"3.0.13","types":["movie","series"],
     "idPrefixes":["tt"],"resources":["catalog",{"name":"meta","types":["movie","series"],"idPrefixes":["tt"]}],
     "catalogs":[{"type":"movie","id":"top","name":"Popular","extra":[{"name":"genre","options":["Action","Drama"]},
       {"name":"search"},{"name":"skip"}]},
       {"type":"movie","id":"imdbRating","extraRequired":["genre"],"extraSupported":["genre"]}]}
    """)))
    #expect(manifest.catalogs.count == 2)
    #expect(manifest.catalogs[0].supports("search"))
    #expect(manifest.catalogs[0].genres == ["Action", "Drama"])
    #expect(manifest.catalogs[1].required == ["genre"])
    #expect(manifest.serves("meta", type: "series", id: "tt0386676"))
    #expect(!manifest.serves("meta", type: "series", id: "kitsu:1"))
    #expect(!manifest.serves("stream", type: "movie", id: "tt1"))
    #expect(Manifest(json: json(#"{"id":"x","name":"X","resources":[]}"#)) == nil)
}

@Test func resourceAddressesEncodeLikeStremio() {
    #expect(AddonEngine.resourceURL("https://a.b", "stream", type: "series", id: "tt0386676:2:3")
        == "https://a.b/stream/series/tt0386676%3A2%3A3.json")
    #expect(AddonEngine.resourceURL("https://a.b", "catalog", type: "movie", id: "top",
                                    extra: [("search", "the office"), ("skip", "100")])
        == "https://a.b/catalog/movie/top/search=the%20office&skip=100.json")
}

@Test func readsAndRanksStreams() throws {
    let streams = (json("""
    [{"name":"Torrentio\\n4k DV","title":"Show.S02E03.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC.mkv\\n👤 50 💾 4.2 GB",
      "url":"https://rd.example/a","behaviorHints":{"filename":"Show.S02E03.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC.mkv"}},
     {"name":"[RD+] Torrentio\\n1080p","title":"Show S02E03 1080p WEB-DL AAC x264\\n💾 1.1 GB 🇬🇧",
      "url":"https://rd.example/b"},
     {"name":"P2P","infoHash":"abc"}]
    """) as! [Any]).compactMap { RawStream(json: $0, addonName: "Torrentio") }
    #expect(streams.count == 3)
    let options = streams.compactMap(\.option)
    #expect(options.count == 2)
    #expect(options[0].quality == "4K")
    #expect(options[0].hdr == "DV")
    #expect(options[0].audioCodec == "Atmos")
    #expect(options[1].cached)
    #expect(options[1].size == "1.1 GB")
    #expect(options[1].languages == ["🇬🇧"])
    // "auto" skips the stream whose audio may not play on the TV (Atmos/DD+ with no AAC copy).
    #expect(pickPreferred(streams)?.url == "https://rd.example/b")
    #expect(pickPreferred(streams, quality: "4K")?.url == "https://rd.example/a")
}

@Test func readsATitleWithEpisodes() throws {
    let meta = json("""
    {"id":"tt0386676","type":"series","name":"The Office","releaseInfo":"2005–2013","imdbRating":"9.0",
     "genres":["Comedy"],"links":[{"name":"Steve Carell","category":"Cast"}],
     "videos":[{"id":"tt0386676:2:1","season":2,"episode":1,"name":"The Dundies","released":"2005-09-20T00:00:00.000Z"},
               {"id":"tt0386676:1:1","season":1,"number":1,"title":"Pilot"},
               {"id":"tt0386676:1:1","season":1,"episode":1,"title":"Pilot again"},
               {"id":"tt0386676:0:1","season":0,"episode":1,"title":"Special"}]}
    """) as! [String: Any]
    let title = AddonEngine.title(meta, type: .series, requested: "tt0386676", addonName: "Cinemeta")
    #expect(title.cast == ["Steve Carell"])
    #expect(title.videos.map(\.id) == ["tt0386676:0:1", "tt0386676:1:1", "tt0386676:2:1"])
    #expect(title.videos[2].title == "The Dundies")
    let watched = title.with(inLibrary: true, progress: ["tt0386676:1:1": (1, true)])
    #expect(watched.inLibrary)
    #expect(watched.nextEpisode?.id == "tt0386676:2:1")
}

@Test func spotsAnotherTitlesDetails() {
    #expect(AddonEngine.contradicts(["id": "tt999"], requested: "tt0386676:2:3"))
    #expect(!AddonEngine.contradicts(["id": "tt0386676"], requested: "tt0386676:2:3"))
    #expect(!AddonEngine.contradicts(["id": "kitsu:1"], requested: "tt0386676"))
}

@Test func readsSubtitles() {
    let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>Hello</i> there\r\nsecond {\\an8}line\r\n\r\n2\r\n00:00:03.2 --> 00:00:04,000\r\nBye\r\n"
    let cues = SubtitleReader.parse(srt)
    #expect(cues == [Cue(s: 1, e: 2.5, t: "Hello there\nsecond line"), Cue(s: 3.2, e: 4, t: "Bye")])
    #expect(SubtitleReader.parse("WEBVTT\n\n00:01:01.000 --> 00:01:02.000 align:start\nVTT line\n")
        == [Cue(s: 61, e: 62, t: "VTT line")])
    // Windows-1252 (an older Spanish file): "canción"
    #expect(SubtitleReader.decode(Data([0x63, 0x61, 0x6e, 0x63, 0x69, 0xf3, 0x6e])) == "canción")
}
