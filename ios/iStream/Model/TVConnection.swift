import FreeMyTVKit
import Foundation
import Observation

/// The phone talking to the TV itself: LG's remote control API (a WebSocket on the TV, ports 3000 and 3001), with
/// this phone's pairing key, then LG's app-to-app channel into Free My TV (tv/web/channel.js). Through it the phone
/// sends what to play and how, and hears what the TV shows; the remote API itself opens apps and inputs, sets the
/// volume and turns the TV off. Waking it is a Wake-on-LAN packet to its address.
@MainActor @Observable
final class TVConnection {
    enum Status: Equatable {
        case unknown
        case connecting
        case off            // the TV doesn't answer
        case needsPairing   // the TV is asking to allow this phone
        case waitingForApp  // connected to the TV, Free My TV isn't open
        case connected      // in Free My TV's channel
    }

    static let appId = "io.freemytv"

    private(set) var status: Status = .unknown
    private(set) var state: PlayerState?
    private(set) var tracks: PlayerTracks = .none

    var isConnected: Bool { status == .connected }
    /// Something is open in Free My TV's player.
    var nowPlaying: PlayerState? { status == .connected && state?.isActive == true ? state : nil }

    /// The TV's address and key (from the Pi's pairing, or a new one the TV gave this phone).
    @ObservationIgnored var ip: String?
    @ObservationIgnored var clientKey: String?
    @ObservationIgnored var onNewKey: ((String) -> Void)?
    @ObservationIgnored var onState: ((PlayerState) -> Void)?
    /// The TV couldn't read a subtitle file itself: read it and send its lines (sendCues).
    @ObservationIgnored var onNeedSubtitle: ((String) -> Void)?
    /// The TV's network cards, for waking it.
    @ObservationIgnored var macs: [String] = []
    @ObservationIgnored private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]

    /// Registered with the TV (it's on), whether or not Free My TV is open.
    var isReachable: Bool { status == .connected || status == .waitingForApp }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var lastAttempt = Date.distantPast
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        return URLSession(configuration: config, delegate: TrustTheTV(), delegateQueue: nil)
    }()

    // MARK: Staying connected

    /// While the app is in front: connect, and keep trying every few seconds when the TV is off or the app closed.
    func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.connectIfNeeded()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        drop(.unknown)
    }

    /// Now (when the app asks, say right after waking the TV), unless a try is under way or was just made.
    func connectIfNeeded() async {
        guard socket == nil, status != .connecting, ip != nil, Date().timeIntervalSince(lastAttempt) > 2 else { return }
        await connect()
    }

    private func connect() async {
        guard let ip else { return }
        lastAttempt = Date()
        status = .connecting
        for address in ["ws://\(ip):3000", "wss://\(ip):3001"] {
            guard let url = URL(string: address) else { continue }
            let task = session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 5))
            task.maximumMessageSize = 4 << 20
            task.resume()
            do {
                try await register(task)
                socket = task
                status = .waitingForApp
                read(task)
                joinApp()
                keepAlive(task)
                return
            } catch {
                task.cancel(with: .goingAway, reason: nil)
                if status == .needsPairing { return }
            }
        }
        status = .off
    }

    /// LG's handshake: the registration with the saved key (the TV asks on screen when it doesn't know it).
    private func register(_ task: URLSessionWebSocketTask) async throws {
        var payload: [String: Any] = [
            "forcePairing": false,
            "pairingType": "PROMPT",
            "manifest": ["appVersion": "1.1", "manifestVersion": 1, "permissions": Self.permissions] as [String: Any],
        ]
        if let clientKey { payload["client-key"] = clientKey }
        try await send(["type": "register", "id": "register", "payload": payload], on: task)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            let message = try await receive(on: task)
            let type = message["type"] as? String
            let body = message["payload"] as? [String: Any]
            if type == "registered" {
                if let key = body?["client-key"] as? String, key != clientKey {
                    clientKey = key
                    onNewKey?(key)
                }
                return
            }
            if type == "response", body?["pairingType"] as? String == "PROMPT" {
                status = .needsPairing
            }
            if type == "error" { throw URLError(.userAuthenticationRequired) }
        }
        throw URLError(.timedOut)
    }

    /// LG's app-to-app channel into Free My TV: answers "waiting" until the app is open, then "connected".
    private func joinApp() {
        guard let socket else { return }
        let message: [String: Any] = [
            "type": "subscribe", "id": "app", "uri": "ssap://webapp/connectToApp", "payload": ["appId": Self.appId],
        ]
        Task { try? await send(message, on: socket) }
    }

    private func read(_ task: URLSessionWebSocketTask) {
        reader?.cancel()
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await TVConnection.receiveStatic(on: task)
                    self?.handle(message)
                } catch {
                    self?.drop(.unknown)
                    return
                }
            }
        }
    }

    private func keepAlive(_ task: URLSessionWebSocketTask) {
        Task { [weak self] in
            while self?.socket === task {
                try? await Task.sleep(for: .seconds(20))
                task.sendPing { _ in }
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String
        let body = message["payload"] as? [String: Any] ?? [:]
        if let id = message["id"] as? String, pending[id] != nil {
            if type == "error" || body["returnValue"] as? Bool == false {
                let text = message["error"] as? String ?? body["errorText"] as? String ?? "The TV said no"
                finish(id, .failure(TVError(message: text)))
            } else {
                finish(id, .success(body))
            }
            return
        }
        if message["id"] as? String == "app" {
            if type == "error" || body["returnValue"] as? Bool == false {
                // Free My TV closed (or isn't installed): ask again in a moment.
                status = .waitingForApp
                state = nil
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.joinApp()
                }
                return
            }
            switch body["state"] as? String ?? "" {
            case "CONNECTED":
                status = .connected
                sendToApp(["type": "hello"])
            case "WAITING_FOR_APP":
                status = .waitingForApp
            case "":
                break
            default:
                // DISCONNECTED or anything else: the app went away.
                status = .waitingForApp
                state = nil
            }
            return
        }
        if type == "p2p" {
            switch body["type"] as? String {
            case "state":
                if let decoded = PlayerState.from(body) {
                    state = decoded
                    onState?(decoded)
                }
            case "tracks":
                if let decoded = PlayerTracks.from(body) { tracks = decoded }
            case "needSubtitle":
                if let url = body["url"] as? String { onNeedSubtitle?(url) }
            default:
                break
            }
        }
    }

    private func drop(_ next: Status) {
        for id in Array(pending.keys) { finish(id, .failure(URLError(.networkConnectionLost))) }
        reader?.cancel()
        reader = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        state = nil
        tracks = .none
        if status != .needsPairing || next != .unknown { status = next }
    }

    // MARK: Talking to Free My TV

    private func sendToApp(_ payload: [String: Any]) {
        guard let socket else { return }
        var body = payload
        body["v"] = 1
        body["id"] = nextId
        nextId += 1
        Task { try? await send(["type": "p2p", "to": Self.appId, "payload": body], on: socket) }
    }

    /// Plays a video: the params the Pi prepared (POST /play with send: false).
    func play(params: Data) throws {
        guard status == .connected, let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] else {
            throw URLError(.notConnectedToInternet)
        }
        sendToApp(["type": "play", "params": object])
    }

    func togglePause() {
        sendToApp(["type": "control", "action": "toggle"])
    }

    func seek(to seconds: Double) {
        sendToApp(["type": "control", "action": "seek", "to": seconds])
    }

    func seek(by seconds: Double) {
        sendToApp(["type": "control", "action": "seek", "by": seconds])
    }

    func stopVideo() {
        sendToApp(["type": "control", "action": "stop"])
    }

    func chooseAudio(_ index: Int) {
        sendToApp(["type": "audio", "index": index])
    }

    /// -1: off
    func chooseSubtitle(_ index: Int) {
        sendToApp(["type": "subs", "index": index])
    }

    /// A subtitle's lines for the TV, a few hundred at a time (the first part replaces, the next ones add).
    func sendCues(_ url: String, _ cues: [Cue]) {
        let parts = stride(from: 0, to: max(cues.count, 1), by: 250).map { Array(cues[$0..<min($0 + 250, cues.count)]) }
        for (index, part) in parts.enumerated() {
            sendToApp(["type": "cues", "url": url, "part": index,
                       "cues": part.map { ["s": $0.s, "e": $0.e, "t": $0.t] as [String: Any] }])
        }
    }

    // MARK: The TV itself (LG's remote API)

    /// One remote API call ("ssap://..."), answered with its payload.
    func request(_ uri: String, _ payload: [String: Any] = [:], timeout: Double = 8) async throws -> [String: Any] {
        guard let socket else { throw TVError(message: "The TV isn't connected") }
        let id = "r\(nextId)"
        nextId += 1
        let message: [String: Any] = ["type": "request", "id": id, "uri": uri, "payload": payload]
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do { try await send(message, on: socket) } catch { finish(id, .failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                finish(id, .failure(TVError(message: "The TV didn't answer")))
            }
        }
    }

    private func finish(_ id: String, _ result: Result<[String: Any], Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    func launch(_ appId: String) async throws {
        _ = try await request("ssap://system.launcher/launch", ["id": appId])
    }

    /// The HDMI inputs with a name of their own (a console's), as Free My TV's shelf shows them.
    func inputs() async throws -> [TVInput] {
        let reply = try await request("ssap://tv/getExternalInputList")
        let devices = reply["devices"] as? [[String: Any]] ?? []
        return devices.compactMap { device in
            guard let appId = device["appId"] as? String, let label = device["label"] as? String,
                  label.range(of: #"^(hdmi|av|component)\s*\d*$"#, options: [.regularExpression, .caseInsensitive]) == nil
            else { return nil }
            return TVInput(id: appId, name: label.replacingOccurrences(of: " Game Console", with: ""))
        }
    }

    /// "up", "down" or "mute" (mute toggles).
    func volume(_ direction: String) async throws {
        switch direction {
        case "up": _ = try await request("ssap://audio/volumeUp")
        case "down": _ = try await request("ssap://audio/volumeDown")
        default:
            let status = try await request("ssap://audio/getStatus")
            _ = try await request("ssap://audio/setMute", ["mute": !(status["mute"] as? Bool ?? false)])
        }
    }

    func turnOff() async throws {
        _ = try await request("ssap://system/turnOff")
    }

    /// What's in front on the TV: an app's id.
    func foregroundApp() async throws -> String? {
        try await request("ssap://com.webos.applicationManager/getForegroundAppInfo")["appId"] as? String
    }

    /// Wake-on-LAN, sent to the TV's own address (no broadcast: that needs Apple's multicast permission).
    func wake() {
        guard let ip else { return }
        WakeOnLAN.send(macs: macs, to: ip)
    }

    /// Free My TV open and the channel joined: waking the TV and opening the app as needed.
    func openFreeMyTV(timeout: TimeInterval = 45) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastWake = Date.distantPast
        var launched = false
        while Date() < deadline {
            if status == .connected { return }
            if isReachable {
                if !launched {
                    launched = true
                    try? await launch(Self.appId)
                }
            } else {
                if Date().timeIntervalSince(lastWake) > 5 {
                    lastWake = Date()
                    wake()
                }
                await connectIfNeeded()
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw TVError(message: isReachable ? "Free My TV didn't open on the TV"
            : status == .needsPairing ? "Allow this phone on the TV first"
            : "The TV didn't turn on. Is \"Turn on via Wi-Fi\" on in its settings?")
    }

    // MARK: Plumbing

    private func send(_ message: [String: Any], on task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(on task: URLSessionWebSocketTask) async throws -> [String: Any] {
        try await TVConnection.receiveStatic(on: task)
    }

    private nonisolated static func receiveStatic(on task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = Data()
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// What the phone asks LG to allow (the same list as the Pi's).
    private static let permissions = [
        "APP_TO_APP", "CLOSE", "CONTROL_AUDIO", "CONTROL_DISPLAY", "CONTROL_INPUT_JOYSTICK",
        "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_MEDIA_RECORDING", "CONTROL_INPUT_TEXT", "CONTROL_INPUT_TV",
        "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER", "CONTROL_TV_SCREEN", "LAUNCH", "LAUNCH_WEBAPP",
        "READ_APP_STATUS", "READ_COUNTRY_INFO", "READ_CURRENT_CHANNEL", "READ_INPUT_DEVICE_LIST",
        "READ_INSTALLED_APPS", "READ_LGE_SDX", "READ_LGE_TV_INPUT_EVENTS", "READ_NETWORK_STATE",
        "READ_NOTIFICATIONS", "READ_POWER_STATE", "READ_RUNNING_APPS", "READ_SETTINGS", "READ_TV_CHANNEL_LIST",
        "READ_TV_CURRENT_TIME", "READ_UPDATE_INFO", "SEARCH", "TEST_OPEN", "TEST_PROTECTED", "TEST_SECURE",
        "UPDATE_FROM_REMOTE_APP", "WRITE_NOTIFICATION_ALERT", "WRITE_NOTIFICATION_TOAST", "WRITE_SETTINGS",
    ]
}

struct TVError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The TV's secure port (3001) has a certificate of its own making: trusted for the TV only.
private final class TrustTheTV: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, space.port == 3001,
           let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
