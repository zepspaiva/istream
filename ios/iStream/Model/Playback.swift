import FreeMyTVKit
import Observation
import SwiftUI

/// Sending something to the TV and following it there: Finding the best stream, Waking the TV, Opening Free My TV,
/// Loading the stream, Playing. Shown as the bar above the tabs until the TV's own Now Playing takes over.
///
/// All from the phone: the add-ons give the stream and the details, the phone wakes the TV and opens Free My TV, and
/// sends the video over its channel.
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
        let content = app.content
        let tv = app.tv
        app.liveActivity.begin(name: title, line: subtitle.isEmpty ? nil : subtitle)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        task = Task {
            do {
                // The stream and the TV at the same time: the TV takes a few seconds to wake.
                async let prepared = content.playParams(type, videoId: videoId, streamUrl: streamUrl)
                async let opened: Void = openTV(tv)
                let (params, _, label) = try await prepared
                if self.subtitle.isEmpty && !label.isEmpty { self.subtitle = label }
                try await opened
                try tv.play(params: params)
                state = .following
                step = "Loading the stream"
                try await follow(tv: tv, url: Playback.url(in: params))
            } catch is CancellationError {
                return
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func openTV(_ tv: TVConnection) async throws {
        if tv.isConnected { return }
        step = tv.isReachable ? "Opening Free My TV" : "Waking the TV"
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.state == .sending else { continue }
                if tv.status == .needsPairing {
                    self.step = "Allow this phone on the TV"
                } else if tv.isReachable && self.step != "Opening Free My TV" {
                    self.step = "Opening Free My TV"
                }
            }
        }
        defer { watcher.cancel() }
        try await tv.openFreeMyTV()
    }

    private static func url(in params: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: params) as? [String: Any])?["url"] as? String
    }

    /// The TV's own reports, until this video plays.
    private func follow(tv: TVConnection, url: String?) async throws {
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

    private func playing() {
        state = .playing
        step = "On the TV"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        // The TV's own Now Playing bar takes over in a moment.
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
