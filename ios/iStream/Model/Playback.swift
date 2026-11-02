import FreeMyTVKit
import Observation
import SwiftUI

/// Sending something to the TV and following it there: Waking the TV, Opening Free My TV, Loading the stream,
/// Playing. Shown as the bar above the tabs until the TV's own Now Playing takes over.
///
/// With Free My TV open and the phone in its channel, the phone sends the video itself (the Pi only prepares it).
/// Otherwise the Pi wakes the TV and opens it there, as in M1, and the phone joins the channel once the app is up.
@MainActor @Observable
final class Playback {
    enum State: Equatable {
        case idle
        case sending
        case following
        case playing
        case failed(String)
    }

    @ObservationIgnored weak var app: AppModel?

    private(set) var state: State = .idle
    private(set) var title = ""
    private(set) var subtitle = ""
    private(set) var step = ""
    private(set) var artwork: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isVisible: Bool { state != .idle }

    /// Plays a movie, or an episode by its video id, on the TV.
    func play(_ type: MediaType, videoId: String, title: String, subtitle: String = "", artwork: URL? = nil,
              streamUrl: String? = nil) {
        guard let app else { return }
        task?.cancel()
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        step = "Finding the best stream"
        state = .sending
        let client = app.client
        let tv = app.tv
        app.liveActivity.begin(name: title, line: subtitle.isEmpty ? nil : subtitle)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        task = Task {
            do {
                if tv.isConnected {
                    let params = try await client.playPayload(type, videoId: videoId, streamUrl: streamUrl)
                    if tv.isConnected {
                        try tv.play(params: params)
                        state = .following
                        step = "Loading the stream"
                        try await followChannel(tv: tv, url: Playback.url(in: params))
                        return
                    }
                }
                let result = try await client.play(type, videoId: videoId, streamUrl: streamUrl)
                if !result.label.isEmpty && self.subtitle.isEmpty { self.subtitle = result.label }
                state = .following
                try await follow(job: result.job, client: client, tv: tv)
            } catch is CancellationError {
                return
            } catch {
                app.handle(error)
                fail(error.localizedDescription)
            }
        }
    }

    private static func url(in params: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: params) as? [String: Any])?["url"] as? String
    }

    /// The TV's own reports, until this video plays.
    private func followChannel(tv: TVConnection, url: String?) async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            guard let now = tv.state, url == nil || now.url == url else { continue }
            if now.isPlaying {
                playing()
                return
            }
        }
        state = .playing
        step = "Sent to the TV"
    }

    /// The Pi's job (it wakes the TV and opens the video there), until the video plays.
    private func follow(job: Int?, client: PiClient, tv: TVConnection) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            await tv.connectIfNeeded()   // the TV is waking: join Free My TV as soon as it's up
            if tv.nowPlaying?.isPlaying == true {
                playing()
                return
            }
            guard let status = try? await client.tvStatus() else { continue }
            if let current = status.job, job == nil || current.id == job {
                step = current.step
                if current.done {
                    if current.ok {
                        playing()
                    } else {
                        fail(current.step)
                    }
                    return
                }
            }
        }
        state = .playing
        step = "Sent to the TV"
    }

    private func playing() {
        state = .playing
        step = "On the TV"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // With the channel up, the TV's own Now Playing bar takes over in a moment.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.state == .playing, self.app?.tv.nowPlaying != nil else { return }
            withAnimation { self.state = .idle }
        }
    }

    private func fail(_ message: String) {
        app?.liveActivity.end()
        state = .failed(message)
        step = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    func dismiss() {
        task?.cancel()
        state = .idle
    }
}
