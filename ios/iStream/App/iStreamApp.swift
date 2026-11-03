import FreeMyTVKit
import SwiftUI

@main
struct iStreamApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
        }
    }
}

/// Setup until there are add-ons and a TV; then the app.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch app.phase {
            case .addons: AddonsSetupView()
            case .findTV: FindTVView()
            case .ready: MainView()
            }
        }
        .animation(.default, value: app.phase)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.becameActive() }
            if phase == .background { app.wentToBackground() }
        }
        .onChange(of: app.phase) { _, phase in
            if phase == .ready { app.becameActive() }
        }
    }
}

/// Four tabs on iPhone; a sidebar on iPad.
struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: "home") { HomeView() }
            Tab("Library", systemImage: "bookmark", value: "library") { LibraryView() }
            Tab("TV", systemImage: "tv", value: "tv") { TVView() }
            Tab("Search", systemImage: "magnifyingglass", value: "search", role: .search) { SearchView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: Bindable(app).showNowPlaying) { NowPlayingView() }
        .task { app.becameActive() }
    }
}
