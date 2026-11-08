import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CouchwireWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
    }
}

/// What's playing on the TV, on the Lock Screen and in the Dynamic Island.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenView(name: context.attributes.name, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "tv")
                        .font(.title2)
                        .foregroundStyle(.pink)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.starting { PlayPauseButton(state: context.state) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.name).font(.headline).lineLimit(1)
                        if let line = context.state.line {
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressLine(state: context.state).padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "tv" : "pause.fill")
                    .foregroundStyle(.pink)
            } compactTrailing: {
                Remaining(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "tv").foregroundStyle(.pink)
            }
            .keylineTint(.pink)
        }
    }
}

struct LockScreenView: View {
    let name: String
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "tv")
                    .font(.title2)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).lineLimit(1)
                    Text(state.line ?? (state.starting ? "Starting on the TV…"
                        : state.isPlaying ? "Playing on the TV" : "Paused on the TV"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !state.starting { PlayPauseButton(state: state) }
            }
            ProgressLine(state: state)
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

struct PlayPauseButton: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        Button(intent: TogglePlaybackIntent(pause: state.isPlaying)) {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.15), in: Circle())
        .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
    }
}

/// The bar moves on by itself while playing (a timer from when the video started), and stands still when paused.
struct ProgressLine: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if state.starting {
                ProgressView(value: 0, total: 1)
            } else if state.isPlaying {
                ProgressView(timerInterval: state.start...state.end, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: min(state.position, max(state.duration, 1)), total: max(state.duration, 1))
            }
            Remaining(state: state)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .tint(.pink)
    }
}

/// Time left: counting down while playing.
struct Remaining: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        if state.starting {
            Text("…")
        } else if state.isPlaying {
            Text(timerInterval: state.start...state.end, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(clock(max(0, state.duration - state.position)))
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
