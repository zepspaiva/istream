import CouchwireKit
import SwiftUI

// MARK: Home

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var home: Home?
    @State private var error: String?
    @State private var showSettings = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if let home {
                        if !home.continueWatching.isEmpty {
                            ContinueRow(items: home.continueWatching) { path.append(Route.title($0.card)) }
                        }
                        if let rows = home.rows {
                            if rows.isEmpty && home.continueWatching.isEmpty {
                                ContentUnavailableView("Nothing here yet", systemImage: "square.stack",
                                                       description: Text("Add catalog add-ons to your Nuvio account."))
                            }
                            ForEach(rows) { CardRow(row: $0) }
                        } else {
                            ErrorState(message: "Your add-ons didn't answer.") { await load() }
                        }
                    } else if let error {
                        ErrorState(message: error) { await load() }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .refreshable { await load() }
            .task {
                if home == nil { await load() }
            }
            .routes()
        }
        .withPlaybackBar()
    }

    private func load() async {
        do {
            home = try await app.content.home()
            error = nil
        } catch is CancellationError {
        } catch {
            app.handle(error)
            self.error = error.localizedDescription
        }
    }
}

/// Continue watching: a tap resumes on the TV; "Details" opens the title.
struct ContinueRow: View {
    @Environment(AppModel.self) private var app
    let items: [Resume]
    let details: (Resume) -> Void

    init(items: [Resume], details: @escaping (Resume) -> Void) {
        self.items = items
        self.details = details
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue watching").font(.title3.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        Button { resume(item) } label: { card(item) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { resume(item) } label: { Label("Resume on the TV", systemImage: "play.fill") }
                                Button { details(item) } label: { Label("Details", systemImage: "info.circle") }
                            }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func card(_ item: Resume) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Artwork(url: item.backgroundURL ?? item.posterURL, placeholder: item.name) }
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Color.accentColor).frame(width: geo.size.width * item.progress)
                        }
                    }
                    .frame(height: 4)
                }
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 240)
        .contentShape(Rectangle())
    }

    private func detail(_ item: Resume) -> String {
        var parts: [String] = []
        if let s = item.season, let e = item.episode { parts.append("S\(s) E\(e)") }
        let minutes = Int(item.remainingMs / 60_000)
        if minutes > 0 { parts.append("\(minutes) min left") }
        return parts.joined(separator: " · ")
    }

    private func resume(_ item: Resume) {
        var subtitle = ""
        if let s = item.season, let e = item.episode {
            subtitle = "S\(s) E\(e)" + (item.episodeTitle.map { " · \($0)" } ?? "")
        }
        app.playback.play(item.type, videoId: item.videoId, title: item.name, subtitle: subtitle,
                          artwork: item.backgroundURL ?? item.posterURL)
    }
}

// MARK: A whole catalog

struct CatalogView: View {
    @Environment(AppModel.self) private var app
    let row: Row
    init(row: Row) { self.row = row }
    @State private var items: [Card] = []
    @State private var loading = false
    @State private var finished = false

    var body: some View {
        ScrollView {
            CardGrid(cards: items) { card in
                if card.id == items.last?.id { Task { await more() } }
            }
            .padding(.vertical)
            if loading { ProgressView().padding() }
        }
        .navigationTitle(row.title)
        .task {
            if items.isEmpty {
                items = row.items
                await more()
            }
        }
    }

    private func more() async {
        guard !loading, !finished else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await app.content.catalog(row, skip: items.count)
            let known = Set(items.map(\.id))
            let fresh = page.filter { !known.contains($0.id) }
            if fresh.isEmpty { finished = true }
            items += fresh
        } catch {
            finished = true
        }
    }
}

// MARK: Search

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var text = ""
    @State private var results: SearchResults?
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let results {
                    if results.movies.isEmpty && results.series.isEmpty {
                        ContentUnavailableView.search(text: text)
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            if !results.series.isEmpty { section("Series", results.series) }
                            if !results.movies.isEmpty { section("Movies", results.movies) }
                        }
                        .padding(.vertical)
                    }
                } else if searching {
                    ProgressView().padding(.top, 80)
                } else if let error {
                    ErrorState(message: error) { await search() }
                } else {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                           description: Text("Movies and series from your add-ons."))
                }
            }
            .navigationTitle("Search")
            .searchable(text: $text, prompt: "Movies and series")
            .task(id: text) { await search() }
            .routes()
        }
        .withPlaybackBar()
    }

    private func section(_ title: String, _ cards: [Card]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold()).padding(.horizontal)
            CardGrid(cards: cards)
        }
    }

    private func search() async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            results = nil
            error = nil
            return
        }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        searching = true
        defer { searching = false }
        do {
            results = try await app.content.search(query)
            error = nil
        } catch is CancellationError {
        } catch {
            app.handle(error)
            self.error = error.localizedDescription
        }
    }
}

// MARK: Library

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var items: [Card]?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let items {
                    if items.isEmpty {
                        ContentUnavailableView("Your library is empty", systemImage: "bookmark",
                                               description: Text("Tap the bookmark on a title to keep it here."))
                    } else {
                        CardGrid(cards: items).padding(.vertical)
                    }
                } else if let error {
                    ErrorState(message: error) { await load() }
                } else {
                    ProgressView().padding(.top, 80)
                }
            }
            .navigationTitle("Library")
            .refreshable { await load() }
            .task { await load() }
            .routes()
        }
        .withPlaybackBar()
    }

    private func load() async {
        do {
            items = try await app.content.library()
            error = nil
        } catch is CancellationError {
        } catch {
            app.handle(error)
            self.error = error.localizedDescription
        }
    }
}
