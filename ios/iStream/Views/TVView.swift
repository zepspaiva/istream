import FreeMyTVKit
import SwiftUI

/// The TV without its remote: what it's doing, the consoles and apps, volume, on and off.
struct TVView: View {
    @Environment(AppModel.self) private var app
    @State private var inputs: [TVInput] = []
    @State private var busy: String?
    @State private var message: String?

    private static let stremio = "io.strem.tv"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: app.tv.isReachable ? "tv.fill" : "tv")
                            .font(.title2)
                            .foregroundStyle(app.tv.isReachable ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(.secondary))
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.tvName ?? "LG TV").font(.headline)
                            Text(statusText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    if app.tv.nowPlaying != nil {
                        Button { app.showNowPlaying = true } label: {
                            Label("Now Playing", systemImage: "play.rectangle.on.rectangle")
                        }
                    }
                    if !app.tv.isReachable {
                        Button { turnOn() } label: {
                            HStack {
                                Label("Turn on the TV", systemImage: "power")
                                Spacer()
                                if busy == "on" { ProgressView() }
                            }
                        }
                        .disabled(busy != nil)
                    }
                }

                Section("Watch") {
                    ForEach(inputs) { input in
                        launchButton(input.name, systemImage: icon(for: input.name), target: input.id)
                    }
                    launchButton("Stremio", systemImage: "play.rectangle", target: Self.stremio)
                    launchButton("Free My TV", systemImage: "square.grid.2x2", target: TVConnection.appId)
                }

                Section("Volume") {
                    HStack {
                        volumeButton("down", systemImage: "speaker.minus.fill", label: "Volume down")
                        Spacer()
                        volumeButton("mute", systemImage: "speaker.slash", label: "Mute")
                        Spacer()
                        volumeButton("up", systemImage: "speaker.plus.fill", label: "Volume up")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                }
                .disabled(!app.tv.isReachable)

                Section {
                    Button(role: .destructive) {
                        run("off") { try await $0.turnOff() }
                    } label: {
                        HStack {
                            Label("Turn off the TV", systemImage: "power")
                            Spacer()
                            if busy == "off" { ProgressView() }
                        }
                    }
                    .disabled(!app.tv.isReachable)
                }

                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("TV")
            .task(id: app.tv.isReachable) {
                if app.tv.isReachable, inputs.isEmpty, let list = try? await app.tv.inputs() { inputs = list }
            }
        }
        .withPlaybackBar()
    }

    private var statusText: String {
        switch app.tv.status {
        case .connected: return "On · Free My TV open"
        case .waitingForApp: return "On"
        case .needsPairing: return "Allow this phone on the TV (its remote)"
        case .off: return "Off or not answering"
        case .connecting: return "Connecting…"
        case .unknown: return "—"
        }
    }

    private func launchButton(_ name: String, systemImage: String, target: String) -> some View {
        Button {
            run(target) { tv in
                if !tv.isReachable { try await wake(tv) }
                try await tv.launch(target)
            }
        } label: {
            HStack {
                Label(name, systemImage: systemImage)
                Spacer()
                if busy == target { ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    private func volumeButton(_ direction: String, systemImage: String, label: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let tv = app.tv
            Task { try? await tv.volume(direction) }
        } label: {
            Image(systemName: systemImage).font(.title2)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    private func icon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("ps") || lower.contains("playstation") { return "playstation.logo" }
        if lower.contains("switch") || lower.contains("xbox") { return "gamecontroller.fill" }
        return "cable.connector.horizontal"
    }

    private func turnOn() {
        run("on") { try await wake($0) }
    }

    /// Wake-on-LAN until the TV answers (about 10 s), up to 40 s.
    private func wake(_ tv: TVConnection) async throws {
        let deadline = Date().addingTimeInterval(40)
        var lastWake = Date.distantPast
        while Date() < deadline {
            if tv.isReachable { return }
            if Date().timeIntervalSince(lastWake) > 5 {
                lastWake = Date()
                tv.wake()
            }
            await tv.connectIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
        }
        throw TVError(message: "The TV didn't turn on. Is \"Turn on via Wi-Fi\" on in its settings?")
    }

    private func run(_ key: String, _ action: @escaping (TVConnection) async throws -> Void) {
        let tv = app.tv
        busy = key
        Task {
            do {
                try await action(tv)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            busy = nil
        }
    }
}
