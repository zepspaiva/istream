import FreeMyTVKit
import Observation
import SwiftUI

/// Sending something to the TV and following it there: Waking the TV, Opening Free My TV, Loading the stream,
/// Playing. Shown as the bar above the tabs.
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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        task = Task {
            do {
                let result = try await client.play(type, videoId: videoId, streamUrl: streamUrl)
                if !result.label.isEmpty && self.subtitle.isEmpty { self.subtitle = result.label }
                state = .following
                try await follow(job: result.job, client: client)
            } catch is CancellationError {
                return
            } catch {
                app.handle(error)
                fail(error.localizedDescription)
            }
        }
    }

    /// Watches the TV service's job until the video plays (or it gives up).
    private func follow(job: Int?, client: PiClient) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            guard let status = try? await client.tvStatus() else { continue }
            if let current = status.job, job == nil || current.id == job {
                step = current.step
                if current.done {
                    if current.ok {
                        state = .playing
                        step = current.step == "Playing" ? "On the TV" : current.step
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
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

    private func fail(_ message: String) {
        state = .failed(message)
        step = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// The TV's start screen waits for OK: this is that OK, from the phone.
    func start() {
        guard let app else { return }
        let client = app.client
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { try? await client.tvButton("ENTER") }
    }

    func pauseOrResume(playing: Bool) {
        guard let app else { return }
        let client = app.client
        Task { try? await client.tvButton(playing ? "PAUSE" : "PLAY") }
    }

    func dismiss() {
        task?.cancel()
        state = .idle
    }
}
