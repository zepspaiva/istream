import FreeMyTVKit
import SwiftUI

/// The TV without its remote: what it's doing, the consoles and apps, volume, off.
struct TVView: View {
    @Environment(AppModel.self) private var app
    @State private var status: TVStatus?
    @State private var inputs: [TVInput] = []
    @State private var busy: String?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: status?.isOn == true ? "tv.fill" : "tv")
                            .font(.title2)
                            .foregroundStyle(status?.isOn == true ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status?.summary ?? "Checking…").font(.headline)
                            if let job = status?.job, !job.done {
                                Text(job.step).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if app.tv.nowPlaying != nil {
                        Button { app.showNowPlaying = true } label: {
                            Label("Now Playing", systemImage: "play.rectangle.on.rectangle")
                        }
                    }
                    LabeledContent("Phone remote", value: remoteStatus)
                        .font(.footnote)
                }

                Section("Watch") {
                    ForEach(inputs) { input in
                        launchButton(input.name, systemImage: icon(for: input.name), target: input.id)
                    }
                    launchButton("Stremio", systemImage: "play.rectangle", target: "stremio")
                    launchButton("Free My TV", systemImage: "square.grid.2x2", target: "freemytv")
                }

                Section("Volume") {
                    HStack {
                        volumeButton("down", systemImage: "speaker.minus.fill", label: "Volume down")
                        Spacer()
                        volumeButton("mute", systemImage: status?.muted == true ? "speaker.slash.fill" : "speaker.slash",
                                     label: "Mute")
                        Spacer()
                        volumeButton("up", systemImage: "speaker.plus.fill", label: "Volume up")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 6)
                }

                Section {
                    Button(role: .destructive) {
                        run("off") { try await $0.tvOff() }
                    } label: {
                        HStack {
                            Label("Turn off the TV", systemImage: "power")
                            Spacer()
                            if busy == "off" { ProgressView() }
                        }
                    }
                    .disabled(status?.isOn != true)
                }

                if let message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("TV")
            .refreshable { await refresh() }
            .task { await poll() }
        }
        .withPlaybackBar()
    }

    private var remoteStatus: String {
        switch app.tv.status {
        case .connected: return "Connected"
        case .waitingForApp: return "Opens with Free My TV"
        case .needsPairing: return "Allow this phone on the TV"
        case .off: return "TV off"
        case .connecting: return "Connecting…"
        case .unknown: return "—"
        }
    }

    private func launchButton(_ name: String, systemImage: String, target: String) -> some View {
        Button {
            run(target) { try await $0.tvLaunch(target) }
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
            run("volume") { try await $0.tvVolume(direction) }
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

    private func run(_ key: String, _ action: @escaping (PiClient) async throws -> Void) {
        let client = app.client
        busy = key
        Task {
            do {
                try await action(client)
                message = nil
            } catch {
                app.handle(error)
                message = error.localizedDescription
            }
            busy = nil
            await refresh()
        }
    }

    private func refresh() async {
        if let fresh = try? await app.client.tvStatus() { status = fresh }
    }

    private func poll() async {
        if inputs.isEmpty, let list = try? await app.client.tvInputs() { inputs = list }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
