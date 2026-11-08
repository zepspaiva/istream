import Foundation
import Testing
@testable import CouchwireKit

// Run on the Mac with:  cd ios/CouchwireKit && swift test

@Test func addressFromWhatPeopleType() {
    #expect(PiClient.address(from: "192.168.1.35")?.absoluteString == "http://192.168.1.35:3000")
    #expect(PiClient.address(from: " 192.168.1.35:3000 ")?.absoluteString == "http://192.168.1.35:3000")
    #expect(PiClient.address(from: "http://pi.local:8000/x")?.absoluteString == "http://pi.local:8000")
    #expect(PiClient.address(from: "") == nil)
}

@Test func urlsKeepEpisodeIds() {
    let client = PiClient(base: URL(string: "http://192.168.1.35:3000")!)
    #expect(client.url([]).absoluteString == "http://192.168.1.35:3000/api/v1")
    #expect(client.url(["streams", "series", "tt0386676:2:3"]).absoluteString
        == "http://192.168.1.35:3000/api/v1/streams/series/tt0386676:2:3")
    #expect(client.url(["search"], query: [URLQueryItem(name: "q", value: "the office")]).absoluteString
        == "http://192.168.1.35:3000/api/v1/search?q=the%20office")
}

@Test func decodesHome() throws {
    let json = """
    {"continueWatching":[{"id":"tt0386676","type":"series","name":"The Office","poster":"https://x/p.jpg",
      "background":null,"logo":"","videoId":"tt0386676:2:3","season":2,"episode":3,"episodeTitle":"Office Olympics",
      "progress":0.4,"remainingMs":720000}],
     "rows":[{"addon":"com.linvo.cinemeta","addonName":"Cinemeta","type":"movie","catalog":"top","title":"Popular",
      "items":[{"id":"tt0111161","type":"movie","name":"The Shawshank Redemption","poster":"https://x/s.jpg",
      "posterShape":"poster","background":null,"logo":null,"year":"1994","rating":"9.3","description":null}]}]}
    """
    let home = try JSONDecoder().decode(Home.self, from: Data(json.utf8))
    #expect(home.continueWatching.first?.logoURL == nil)
    #expect(home.rows?.first?.items.first?.year == "1994")
}

@Test func decodesAHomeWithoutAddons() throws {
    let home = try JSONDecoder().decode(Home.self, from: Data(#"{"continueWatching":[],"rows":null}"#.utf8))
    #expect(home.rows == nil)
}

@Test func nextEpisodeIsTheOneAfterTheLastWatched() throws {
    func video(_ s: Int, _ e: Int, watched: Bool = false, progress: Double = 0) -> String {
        #"{"id":"x:\#(s):\#(e)","season":\#(s),"episode":\#(e),"title":null,"overview":null,"thumbnail":null,"#
            + #""released":"2005-01-01T00:00:00.000Z","progress":\#(progress),"watched":\#(watched)}"#
    }
    let json = """
    {"id":"x","type":"series","name":"Show","poster":null,"background":null,"logo":null,"year":null,"rating":null,
     "description":null,"addonName":"Cinemeta","runtime":null,"released":null,"country":null,"genres":[],"cast":[],
     "director":[],"certification":null,"status":null,"trailer":null,"inLibrary":false,"progress":null,
     "videos":[\(video(0, 1)),\(video(1, 1, watched: true)),\(video(1, 2)),\(video(2, 1))]}
    """
    let title = try JSONDecoder().decode(Title.self, from: Data(json.utf8))
    #expect(title.seasons == [1, 2, 0])
    #expect(title.nextEpisode?.id == "x:1:2")
}

@Test func errorsReadTheMessage() {
    let error = PiError.from(status: 401, data: Data(#"{"status":401,"message":"Sign in first"}"#.utf8))
    #expect(error.message == "Sign in first")
    #expect(error.needsSignIn)
    #expect(PiError.from(status: 502, data: Data(#"{"error":"The TV is off"}"#.utf8)).message == "The TV is off")
}

@Test func decodesTheTVsState() {
    let payload: [String: Any] = [
        "type": "state", "v": 1, "screen": "playing", "title": "The Office", "show": "The Office", "season": 2,
        "episode": 3, "episodeTitle": "Office Olympics", "poster": NSNull(), "backdrop": "https://x/b.jpg",
        "label": "1080p", "url": "https://x/v.mkv", "position": 125, "duration": 1320, "buffering": false,
        "ref": ["type": "series", "contentId": "tt0386676", "videoId": "tt0386676:2:3"],
    ]
    let state = PlayerState.from(payload)
    #expect(state?.isPlaying == true)
    #expect(state?.episodeLine == "S2 E3 · Office Olympics")
    #expect(state?.ref?.videoId == "tt0386676:2:3")
    #expect(state?.artworkURL?.absoluteString == "https://x/b.jpg")
}

@Test func decodesTheTVsHomeScreen() {
    let state = PlayerState.from(["type": "state", "screen": "home", "title": NSNull(), "position": 0, "duration": 0])
    #expect(state?.isActive == false)
}

@Test func decodesTracks() {
    let tracks = PlayerTracks.from([
        "type": "tracks", "audio": [["name": "English", "lang": "en", "on": true] as [String: Any]],
        "subs": [["name": "Spanish", "lang": "es", "on": false] as [String: Any]],
    ])
    #expect(tracks?.audio.first?.on == true)
    #expect(tracks?.subs.count == 1)
}
