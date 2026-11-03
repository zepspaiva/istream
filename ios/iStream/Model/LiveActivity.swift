import ActivityKit
import FreeMyTVKit
import Foundation

/// The Lock Screen and Dynamic Island's "Now playing on the TV": started when the TV plays something, moved along by
/// the TV's reports while the app runs (its bar keeps moving by itself after that), ended when the TV goes back home.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NowPlayingAttributes>?
    private var url: String?
    private var sent: NowPlayingAttributes.ContentState?

    init() {
        activity = Activity<NowPlayingAttributes>.activities.first
    }

    func update(_ state: PlayerState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if state.screen == "home" {
            end()
            return
        }
        guard state.isActive else { return }
        // The start screen: "Starting on the TV" until the video has a length.
        if state.duration <= 0 {
            if activity == nil {
                begin(name: state.name, line: state.episodeLine)
                url = state.url
            }
            return
        }
        let content = NowPlayingAttributes.ContentState(
            isPlaying: state.isPlaying, position: state.position, duration: state.duration, at: Date(),
            line: state.episodeLine)
        if activity == nil || (url != nil && state.url != nil && url != state.url) {
            start(name: state.name, content: content, url: state.url)
            return
        }
        url = state.url
        // Only when it changed: playing or paused, or the place moved off what the clock says (a seek).
        if let sent, !sent.starting, sent.isPlaying == content.isPlaying, sent.duration == content.duration,
           abs(sent.position(at: content.at) - content.position) < 5 {
            return
        }
        send(content)
    }

    /// Right when Play is tapped (an activity can only start while the app is in front): "Starting on the TV".
    func begin(name: String, line: String?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = NowPlayingAttributes.ContentState(isPlaying: false, position: 0, duration: 0, at: Date(),
                                                        line: line)
        start(name: name, content: content, url: nil)
    }

    func end() {
        let ending = Activity<NowPlayingAttributes>.activities
        activity = nil
        sent = nil
        url = nil
        Task {
            for item in ending { await item.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private func start(name: String, content: NowPlayingAttributes.ContentState, url: String?) {
        let old = Activity<NowPlayingAttributes>.activities
        Task {
            for item in old { await item.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            activity = try Activity.request(attributes: NowPlayingAttributes(name: name),
                                            content: ActivityContent(state: content, staleDate: nil),
                                            pushType: nil)
            sent = content
            self.url = url
        } catch {
            activity = nil
        }
    }

    private func send(_ content: NowPlayingAttributes.ContentState) {
        guard let activity else { return }
        sent = content
        Task { await activity.update(ActivityContent(state: content, staleDate: content.end.addingTimeInterval(60))) }
    }
}

/// The Live Activity's button, with the app in the background: the phone connects to the TV for a moment and presses
/// Pause or Play there (LG's media controls act on Free My TV's video), and the activity shows the new state at once.
@MainActor
enum BackgroundRemote {
    static func setPaused(_ pause: Bool) async {
        let defaults = UserDefaults.standard
        let tv = TVConnection()
        tv.ip = defaults.string(forKey: "tvIP")
        tv.clientKey = Keychain.read("tvClientKey")
        if tv.ip != nil, tv.clientKey != nil {
            await tv.connectIfNeeded()
            if tv.isReachable {
                _ = try? await tv.request(pause ? "ssap://media.controls/pause" : "ssap://media.controls/play")
            }
            tv.stop()
        }
        let now = Date()
        for activity in Activity<NowPlayingAttributes>.activities {
            var state = activity.content.state
            state.position = state.position(at: now)
            state.at = now
            state.isPlaying = !pause
            await activity.update(ActivityContent(state: state, staleDate: state.end.addingTimeInterval(60)))
        }
    }
}
