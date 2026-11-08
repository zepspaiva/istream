import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Something the Pi said no to, or couldn't be reached for. `message` is written for people.
public struct PiError: LocalizedError, Sendable, Equatable {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
    /// The session is gone (signed out elsewhere, or expired): sign in again.
    public var needsSignIn: Bool { status == 401 }

    static func from(status: Int, data: Data) -> PiError {
        struct Body: Decodable {
            let message: String?
            let error: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let text = body?.message ?? body?.error ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        return PiError(status: status, message: text)
    }
}

/// The Pi's API (v1). A value: make a new one when the address, token or profile changes.
public struct PiClient: Sendable {
    public let base: URL
    public let token: String?
    public let profile: Int?
    private let session: URLSession

    /// No cookies (the bearer token is the session) and a generous cache for posters.
    public static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        return URLSession(configuration: config)
    }()

    public init(base: URL, token: String? = nil, profile: Int? = nil, session: URLSession = PiClient.sharedSession) {
        self.base = base
        self.token = token
        self.profile = profile
        self.session = session
    }

    /// "192.168.1.35", "192.168.1.35:3000" or a full URL → http://192.168.1.35:3000
    public static func address(from text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "http://" + value }
        guard var comps = URLComponents(string: value), let host = comps.host, !host.isEmpty else { return nil }
        if comps.port == nil && comps.scheme == "http" { comps.port = 3000 }
        comps.path = ""
        comps.query = nil
        return comps.url
    }

    // MARK: Account

    public func info() async throws -> ServerInfo { try await get([]) }

    public func login(email: String, password: String) async throws -> LoginResult {
        try await send("POST", ["auth", "login"], body: ["email": email, "password": password])
    }

    public func logout() async throws {
        let _: Done = try await send("POST", ["auth", "logout"])
    }

    public func me() async throws -> Me { try await get(["me"]) }
    public func profiles() async throws -> [Profile] { try await get(["profiles"]) }

    // MARK: Browsing

    public func home() async throws -> Home { try await get(["home"], timeout: 60) }

    public func catalog(_ row: Row, skip: Int) async throws -> [Card] {
        let page: Items = try await get(["catalog", row.addon, row.type, row.catalog],
                                        query: [URLQueryItem(name: "skip", value: String(skip))])
        return page.items
    }

    public func search(_ text: String) async throws -> SearchResults {
        try await get(["search"], query: [URLQueryItem(name: "q", value: text)], timeout: 45)
    }

    public func title(_ type: MediaType, _ id: String) async throws -> Title {
        try await get(["meta", type.rawValue, id])
    }

    public func streams(_ type: MediaType, videoId: String) async throws -> Streams {
        try await get(["streams", type.rawValue, videoId], timeout: 60)
    }

    public func library() async throws -> [Card] {
        let page: Items = try await get(["library"])
        return page.items
    }

    public func addToLibrary(_ card: Card) async throws {
        var body: [String: Any] = ["id": card.id, "type": card.type.rawValue, "name": card.name]
        body["poster"] = card.poster
        body["background"] = card.background
        body["description"] = card.description
        body["year"] = card.year
        let _: Done = try await send("POST", ["library"], body: body)
    }

    public func removeFromLibrary(_ type: MediaType, _ id: String) async throws {
        let _: Done = try await send("DELETE", ["library", type.rawValue, id])
    }

    // MARK: Playing

    /// Sends a movie or an episode (its video id) to the TV. Without `streamUrl` the Pi picks the best stream.
    public func play(_ type: MediaType, videoId: String, streamUrl: String? = nil) async throws -> PlayResult {
        var body: [String: Any] = ["type": type.rawValue, "id": videoId]
        body["streamUrl"] = streamUrl
        return try await send("POST", ["play"], body: body, timeout: 90)
    }

    /// What the phone sends the TV itself (over LG's channel): the play message's params, as JSON.
    public func playPayload(_ type: MediaType, videoId: String, streamUrl: String? = nil) async throws -> Data {
        var body: [String: Any] = ["type": type.rawValue, "id": videoId, "send": false]
        body["streamUrl"] = streamUrl
        let data = try await sendRaw("POST", ["play"], body: body, timeout: 90)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"], JSONSerialization.isValidJSONObject(payload) else {
            throw PiError(status: 200, message: "The Pi sent something unexpected for this video")
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    /// Where the TV got to (seconds), saved in the account.
    public func saveProgress(_ ref: PlayerRef, season: Int?, episode: Int?, position: Double, duration: Double)
        async throws {
        var body: [String: Any] = [
            "type": ref.type ?? (ref.videoId.contains(":") ? "series" : "movie"),
            "contentId": ref.contentId, "videoId": ref.videoId, "position": position, "duration": duration,
        ]
        body["season"] = season
        body["episode"] = episode
        let _: Done = try await send("POST", ["progress"], body: body)
    }

    // MARK: The TV

    /// The TV's address and the Pi's pairing key, so the app can talk to the TV itself.
    public func tvPairing() async throws -> TVPairing { try await get(["tv", "pairing"]) }

    public func tvStatus() async throws -> TVStatus { try await get(["tv", "status"], timeout: 10) }

    public func tvInputs() async throws -> [TVInput] {
        let list: TVInputs = try await get(["tv", "inputs"])
        return list.inputs
    }

    /// An input id or name, "stremio", "freemytv", or an app id. Wakes the TV first.
    public func tvLaunch(_ target: String) async throws {
        let _: Done = try await send("POST", ["tv", "launch"], body: ["target": target])
    }

    public func tvOff() async throws {
        let _: Done = try await send("POST", ["tv", "off"])
    }

    /// "up", "down" or "mute"
    public func tvVolume(_ direction: String) async throws {
        let _: Done = try await send("POST", ["tv", "volume"], body: ["direction": direction])
    }

    /// UP, DOWN, LEFT, RIGHT, ENTER, BACK, HOME, PLAY, PAUSE...
    public func tvButton(_ name: String) async throws {
        let _: Done = try await send("POST", ["tv", "button"], body: ["name": name])
    }

    // MARK: Plumbing

    func url(_ segments: [String], query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let extra = segments.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
        var path = comps.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        comps.percentEncodedPath = ([path + "/api/v1"] + extra).joined(separator: "/")
        comps.queryItems = query.isEmpty ? nil : query
        return comps.url ?? base
    }

    private func get<T: Decodable>(_ segments: [String], query: [URLQueryItem] = [], timeout: TimeInterval = 30)
        async throws -> T {
        try await send("GET", segments, query: query, timeout: timeout)
    }

    private func send<T: Decodable>(_ method: String, _ segments: [String], query: [URLQueryItem] = [],
                                    body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> T {
        let data = try await sendRaw(method, segments, query: query, body: body, timeout: timeout)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PiError(status: 200, message: "The Pi sent something unexpected (\(error))")
        }
    }

    private func sendRaw(_ method: String, _ segments: [String], query: [URLQueryItem] = [],
                         body: [String: Any]? = nil, timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: url(segments, query: query), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let profile { request.setValue(String(profile), forHTTPHeaderField: "X-Profile") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PiError(status: 0, message: "Can't reach the Pi at \(base.host() ?? base.absoluteString). "
                + "Is the phone on the home Wi-Fi?")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw PiError.from(status: status, data: data) }
        return data
    }
}
