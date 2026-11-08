import CouchwireKit
import SwiftUI

/// What to choose a source for: a movie, or one episode.
struct SourcesRequest: Identifiable {
    let type: MediaType
    let videoId: String
    let name: String
    let subtitle: String
    let artwork: URL?

    var id: String { videoId }
}

struct TitleView: View {
    @Environment(AppModel.self) private var app
    let card: Card
    init(card: Card) { self.card = card }
    @State private var title: Title?
    @State private var error: String?
    @State private var season = 1
    @State private var sources: SourcesRequest?
    @State private var inLibrary = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    facts
                    actions
                    if let text = title?.description ?? card.description, !text.isEmpty {
                        Text(text).font(.body)
                    }
                    if let title, !title.cast.isEmpty {
                        Text("Cast: \(title.cast.prefix(6).joined(separator: ", "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    if let title, title.type == .series, !title.videos.isEmpty {
                        episodes(title)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $sources) { SourcesSheet(request: $0) }
    }

    // MARK: Parts

    private var header: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { Artwork(url: title?.backgroundURL ?? card.backgroundURL ?? card.posterURL) }
            .overlay {
                LinearGradient(colors: [.clear, .clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Group {
                    if let logo = title?.logoURL ?? card.logoURL {
                        AsyncImage(url: logo) { image in
                            image.resizable().scaledToFit()
                        } placeholder: {
                            name
                        }
                    } else {
                        name
                    }
                }
                .frame(maxWidth: 260, maxHeight: 84, alignment: .bottomLeading)
                .padding(.horizontal)
            }
            .clipped()
    }

    private var name: some View {
        Text(title?.name ?? card.name).font(.largeTitle.bold()).lineLimit(2).minimumScaleFactor(0.6)
    }

    private var facts: some View {
        var parts: [String] = []
        if let year = title?.year ?? card.year { parts.append(year) }
        if let runtime = title?.runtime { parts.append(runtime) }
        if let rating = title?.rating ?? card.rating { parts.append("★ \(rating)") }
        if let certification = title?.certification { parts.append(certification) }
        if let genres = title?.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        return Text(parts.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { playMain() } label: {
                Label(playLabel, systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(title == nil)

            Button { chooseSourceMain() } label: {
                Image(systemName: "list.bullet")
            }
            .buttonStyle(.bordered)
            .disabled(title == nil)
            .accessibilityLabel("Choose source")

            Button { toggleLibrary() } label: {
                Image(systemName: inLibrary ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(.bordered)
            .disabled(title == nil)
            .accessibilityLabel(inLibrary ? "Remove from library" : "Add to library")
        }
        .controlSize(.large)
    }

    private func episodes(_ title: Title) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if title.seasons.count > 1 {
                Picker("Season", selection: $season) {
                    ForEach(title.seasons, id: \.self) { number in
                        Text(number == 0 ? "Specials" : "Season \(number)").tag(number)
                    }
                }
                .pickerStyle(.menu)
                .padding(.leading, -10)
            } else {
                Text("Episodes").font(.title3.bold())
            }
            ForEach(title.videos.filter { $0.season == season }) { video in
                Button { play(video, in: title) } label: { EpisodeRow(video: video) }
                    .buttonStyle(.plain)
                    .disabled(!video.hasAired)
                    .contextMenu {
                        Button { play(video, in: title) } label: { Label("Play on the TV", systemImage: "play.fill") }
                        Button { chooseSource(video, in: title) } label: {
                            Label("Choose source", systemImage: "list.bullet")
                        }
                    }
            }
        }
        .padding(.top, 8)
    }

    // MARK: Actions

    private var playLabel: String {
        guard let title else { return "Play on TV" }
        if title.type == .movie {
            return (title.progress ?? 0) > 0.02 ? "Resume on TV" : "Play on TV"
        }
        guard let next = title.nextEpisode else { return "Play on TV" }
        return "\(next.progress > 0.02 ? "Resume" : "Play") S\(next.season) E\(next.episode)"
    }

    private func playMain() {
        guard let title else { return }
        if title.type == .movie {
            app.playback.play(.movie, videoId: title.id, title: title.name,
                              artwork: title.backgroundURL ?? title.posterURL)
        } else if let next = title.nextEpisode {
            play(next, in: title)
        }
    }

    private func chooseSourceMain() {
        guard let title else { return }
        if title.type == .movie {
            sources = SourcesRequest(type: .movie, videoId: title.id, name: title.name, subtitle: "",
                                     artwork: title.backgroundURL ?? title.posterURL)
        } else if let next = title.nextEpisode {
            chooseSource(next, in: title)
        }
    }

    private func episodeLabel(_ video: Video) -> String {
        "S\(video.season) E\(video.episode)" + (video.title.map { " · \($0)" } ?? "")
    }

    private func play(_ video: Video, in title: Title) {
        app.playback.play(.series, videoId: video.id, title: title.name, subtitle: episodeLabel(video),
                          artwork: video.thumbnailURL ?? title.backgroundURL ?? title.posterURL)
    }

    private func chooseSource(_ video: Video, in title: Title) {
        sources = SourcesRequest(type: .series, videoId: video.id, name: title.name, subtitle: episodeLabel(video),
                                 artwork: video.thumbnailURL ?? title.backgroundURL)
    }

    private func toggleLibrary() {
        guard let title else { return }
        let adding = !inLibrary
        inLibrary = adding
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let content = app.content
        Task {
            do {
                if adding {
                    try await content.addToLibrary(title.card)
                } else {
                    try await content.removeFromLibrary(title.type, title.id)
                }
            } catch {
                inLibrary = !adding
                self.error = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard title == nil else { return }
        do {
            let loaded = try await app.content.title(card.type, card.id)
            title = loaded
            inLibrary = loaded.inLibrary
            season = loaded.nextEpisode?.season ?? loaded.seasons.first ?? 1
            error = nil
        } catch is CancellationError {
        } catch {
            app.handle(error)
            self.error = error.localizedDescription
        }
    }
}

struct EpisodeRow: View {
    let video: Video

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear
                .frame(width: 128, height: 72)
                .overlay { Artwork(url: video.thumbnailURL) }
                .overlay(alignment: .bottom) {
                    if video.progress > 0.02 && !video.watched {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.4))
                                Rectangle().fill(Color.accentColor).frame(width: geo.size.width * video.progress)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(video.episode). \(video.title ?? "Episode \(video.episode)")")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if video.watched {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
                if !video.hasAired, let date = video.releaseDate {
                    Text("Airs \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let overview = video.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .opacity(video.hasAired ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}

/// Every stream the add-ons have that the TV can play; picking one plays it.
struct SourcesSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: SourcesRequest
    init(request: SourcesRequest) { self.request = request }
    @State private var result: Streams?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    if result.streams.isEmpty {
                        ContentUnavailableView("No streams", systemImage: "exclamationmark.magnifyingglass",
                                               description: Text("None of your add-ons has a link the TV can play."))
                    } else {
                        List(result.streams) { stream in
                            Button { pick(stream) } label: { StreamRow(stream: stream, best: stream.url == result.best) }
                                .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                    }
                } else if let error {
                    ErrorState(message: error) { await load() }
                } else {
                    ProgressView("Asking your add-ons…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(request.subtitle.isEmpty ? request.name : request.subtitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            result = try await app.content.streams(request.type, videoId: request.videoId)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pick(_ stream: StreamOption) {
        app.playback.play(request.type, videoId: request.videoId, title: request.name, subtitle: request.subtitle,
                          artwork: request.artwork, streamUrl: stream.url)
        dismiss()
    }
}

struct StreamRow: View {
    let stream: StreamOption
    let best: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let quality = stream.quality {
                    Text(quality)
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                if let hdr = stream.hdr {
                    Text(hdr).font(.caption.bold()).foregroundStyle(.secondary)
                }
                if stream.cached {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.yellow)
                        .accessibilityLabel("Ready to start")
                }
                if best {
                    Text("Best").font(.caption.weight(.semibold)).foregroundStyle(.tint)
                }
                Spacer()
                if let size = stream.size {
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(stream.title).font(.subheadline).lineLimit(2)
            Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var details: String {
        ([stream.addon, stream.videoCodec, stream.audioCodec].compactMap { $0 } + stream.languages)
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
