import FreeMyTVKit
import SwiftUI

/// The remote for what's playing on the TV: the place, pause, ±10 s, audio, subtitles, volume and off.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing = false
    @State private var scrubAt: Double = 0
    /// Where the phone asked to go, until the TV reports from there (so the bar doesn't jump back meanwhile).
    @State private var sentTo: Double?

    var body: some View {
        let now = app.tv.nowPlaying
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let now {
                        artwork(now)
                        heading(now)
                        timeline(now)
                        transport(now)
                        choices
                    } else {
                        ContentUnavailableView("Nothing playing", systemImage: "tv",
                                               description: Text(waitingText))
                            .padding(.top, 60)
                    }
                    volume
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDragIndicator(.visible)
        .onChange(of: now?.position) { _, position in
            if let target = sentTo, let position, abs(position - target) < 15 { sentTo = nil }
        }
    }

    private var waitingText: String {
        switch app.tv.status {
        case .off: return "The TV is off."
        case .needsPairing: return "Allow this phone on the TV."
        case .waitingForApp: return "Free My TV isn't open on the TV."
        default: return "Connecting to the TV…"
        }
    }

    // MARK: Parts

    private func artwork(_ now: PlayerState) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { Artwork(url: now.artworkURL, placeholder: now.name) }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            .padding(.top, 8)
    }

    private func heading(_ now: PlayerState) -> some View {
        VStack(spacing: 4) {
            Text(now.name).font(.title2.bold()).multilineTextAlignment(.center)
            if let line = now.episodeLine {
                Text(line).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if now.screen == "intro" {
                Label("Starting on the TV", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            } else if now.buffering == true {
                Label("Loading…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func timeline(_ now: PlayerState) -> some View {
        let duration = max(now.duration, 1)
        let shown = scrubbing ? scrubAt : (sentTo ?? now.position)
        return VStack(spacing: 4) {
            Slider(value: Binding(get: { min(shown, duration) }, set: { scrubAt = $0 }), in: 0...duration,
                   onEditingChanged: { editing in
                if editing {
                    scrubAt = shown
                    scrubbing = true
                } else {
                    scrubbing = false
                    sentTo = scrubAt
                    app.tv.seek(to: scrubAt)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            })
            .disabled(now.duration <= 0)
            HStack {
                Text(clock(shown))
                Spacer()
                Text("-" + clock(max(0, duration - shown)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func transport(_ now: PlayerState) -> some View {
        HStack(spacing: 44) {
            Button { jump(-10, now) } label: { Image(systemName: "gobackward.10") }
                .accessibilityLabel("Back 10 seconds")
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                app.tv.togglePause()
            } label: {
                Image(systemName: now.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
            }
            .accessibilityLabel(now.isPlaying ? "Pause" : "Play")
            Button { jump(10, now) } label: { Image(systemName: "goforward.10") }
                .accessibilityLabel("Forward 10 seconds")
        }
        .font(.system(size: 30))
        .buttonStyle(.plain)
        .disabled(now.screen == "intro")
    }

    private var choices: some View {
        let tracks = app.tv.tracks
        return HStack(spacing: 12) {
            Menu {
                if tracks.audio.isEmpty {
                    Text("Only one audio track")
                }
                ForEach(Array(tracks.audio.enumerated()), id: \.offset) { index, track in
                    Button { app.tv.chooseAudio(index) } label: {
                        if track.on { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                    }
                }
            } label: {
                pill("Audio", value: tracks.audio.first(where: \.on)?.name ?? "Default", systemImage: "waveform")
            }
            Menu {
                Button { app.tv.chooseSubtitle(-1) } label: {
                    if !tracks.subs.contains(where: \.on) { Label("Off", systemImage: "checkmark") } else { Text("Off") }
                }
                ForEach(Array(tracks.subs.enumerated()), id: \.offset) { index, track in
                    Button { app.tv.chooseSubtitle(index) } label: {
                        if track.on { Label(track.name, systemImage: "checkmark") } else { Text(track.name) }
                    }
                }
            } label: {
                pill("Subtitles", value: tracks.subs.first(where: \.on)?.name ?? "Off", systemImage: "captions.bubble")
            }
        }
    }

    private func pill(_ title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(.primary)
    }

    private var volume: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                roundButton("speaker.minus.fill", label: "Volume down") { tvCall { try await $0.tvVolume("down") } }
                roundButton("speaker.slash.fill", label: "Mute") { tvCall { try await $0.tvVolume("mute") } }
                roundButton("speaker.plus.fill", label: "Volume up") { tvCall { try await $0.tvVolume("up") } }
            }
            HStack(spacing: 12) {
                if app.tv.nowPlaying != nil {
                    Button(role: .destructive) {
                        app.tv.stopVideo()
                        dismiss()
                    } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button(role: .destructive) {
                    tvCall { try await $0.tvOff() }
                    dismiss()
                } label: {
                    Label("Turn off TV", systemImage: "power").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(.top, 8)
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Actions

    private func jump(_ seconds: Double, _ now: PlayerState) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let from = sentTo ?? now.position
        sentTo = max(0, min(now.duration, from + seconds))
        app.tv.seek(by: seconds)
    }

    /// Volume and power still go through the Pi (it reaches the TV on any screen).
    private func tvCall(_ action: @escaping (PiClient) async throws -> Void) {
        let client = app.client
        Task { try? await action(client) }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
