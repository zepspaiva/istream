import CouchwireKit
import SwiftUI

/// Where a tap goes inside a tab.
enum Route: Hashable {
    case title(Card)
    case catalog(Row)
}

extension View {
    /// The screens any tab can push.
    func routes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .title(let card): TitleView(card: card)
            case .catalog(let row): CatalogView(row: row)
            }
        }
    }

    /// The "now sending to the TV" bar, above the tab bar.
    func withPlaybackBar() -> some View {
        safeAreaInset(edge: .bottom) { PlaybackBar() }
    }
}

/// An image from the web, filling its frame, with the name while it loads (or when there's none).
struct Artwork: View {
    let url: URL?
    var placeholder = ""

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Text(placeholder)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(6)
                }
            }
        }
    }
}

/// A poster and its name. Without a width it fills its grid cell.
struct PosterView: View {
    let card: Card
    var width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay { Artwork(url: card.posterURL, placeholder: card.name) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(card.name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

/// Posters in as many columns as fit.
struct CardGrid: View {
    let cards: [Card]
    var onAppear: (Card) -> Void = { _ in }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 105, maximum: 170), spacing: 12)], spacing: 16) {
            ForEach(cards) { card in
                NavigationLink(value: Route.title(card)) { PosterView(card: card) }
                    .buttonStyle(.plain)
                    .onAppear { onAppear(card) }
            }
        }
        .padding(.horizontal)
    }
}

/// A row of posters with its name; the name opens the whole catalog.
struct CardRow: View {
    let row: Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: Route.catalog(row)) {
                HStack(spacing: 4) {
                    Text(row.title).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(row.items) { card in
                        NavigationLink(value: Route.title(card)) { PosterView(card: card, width: 116) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Something went wrong, with a way to try again.
struct ErrorState: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") { Task { await retry() } }
                .buttonStyle(.bordered)
        }
    }
}

/// A profile's avatar, or its colour and initial.
struct ProfileBadge: View {
    let profile: Profile?
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: profile?.color) ?? .accentColor)
            if let url = profile?.avatarURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initial
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initial: some View {
        Text(String(profile?.name.prefix(1) ?? "?"))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
    }
}

/// Above the tabs: what's being sent to the TV, then what the TV is playing (a tap opens Now Playing).
struct PlaybackBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let playback = app.playback
        Group {
            if playback.isVisible {
                sending(playback)
            } else if let now = app.tv.nowPlaying {
                playing(now)
            }
        }
        .animation(.snappy, value: playback.isVisible)
        .animation(.snappy, value: app.tv.nowPlaying?.url)
    }

    private func sending(_ playback: Playback) -> some View {
        bar(artwork: playback.artwork) {
            Text(playback.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(playback.subtitle.isEmpty ? playback.step : "\(playback.step) · \(playback.subtitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } trailing: {
            switch playback.state {
            case .sending, .following:
                ProgressView()
            case .playing:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }
            Button {
                withAnimation { playback.dismiss() }
            } label: {
                Image(systemName: "xmark").font(.footnote.bold()).foregroundStyle(.secondary).padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide")
        }
    }

    private func playing(_ now: PlayerState) -> some View {
        bar(artwork: now.artworkURL) {
            Text(now.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(now.episodeLine ?? (now.screen == "intro" ? "Starting on the TV" : "On the TV"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } trailing: {
            if now.screen == "intro" {
                ProgressView()
            } else {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    app.tv.togglePause()
                } label: {
                    Image(systemName: now.isPlaying ? "pause.fill" : "play.fill").font(.title3).padding(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(now.isPlaying ? "Pause" : "Play")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.showNowPlaying = true }
    }

    private func bar<Middle: View, Trailing: View>(artwork: URL?, @ViewBuilder middle: () -> Middle,
                                                   @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Artwork(url: artwork)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) { middle() }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension Color {
    /// "#2563EB" → a colour; nil for anything else.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
