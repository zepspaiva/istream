import ActivityKit
import AppIntents
import Foundation

// Shared by the app and its widget extension: what the Live Activity shows, and its play/pause button.

struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isPlaying: Bool
        /// Seconds into the video at `at`.
        var position: Double
        var duration: Double
        var at: Date
        /// "S2 E3 · Office Olympics"
        var line: String?

        /// Sent, not playing yet (the TV doesn't know the video's length).
        var starting: Bool { duration <= 0 }

        /// When the video started (as if it had played without stops): the progress bar's timer counts from it.
        var start: Date { at.addingTimeInterval(-position) }
        var end: Date { start.addingTimeInterval(max(duration, 1)) }

        /// Where it is now, by the clock (the TV's last report, moved on while playing).
        func position(at now: Date) -> Double {
            isPlaying ? min(duration, position + now.timeIntervalSince(at)) : position
        }
    }

    var name: String
}

/// The Live Activity's play/pause button. It runs in the app (woken in the background) and asks the Pi to press
/// Pause or Play on the TV.
struct TogglePlaybackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or pause on the TV"
    static let isDiscoverable = false

    @Parameter(title: "Pause")
    var pause: Bool

    init() {}

    init(pause: Bool) {
        self.pause = pause
    }

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await BackgroundRemote.setPaused(pause)
        #endif
        return .result()
    }
}
