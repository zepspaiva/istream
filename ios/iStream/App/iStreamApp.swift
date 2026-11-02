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

/// Setup until there's a Pi, an account and a profile; then the app.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .connect: ConnectView()
            case .signIn: SignInView()
            case .pickProfile: ProfilePickerView()
            case .ready: MainView()
            }
        }
        .animation(.default, value: app.phase)
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
        .task {
            if app.profiles.isEmpty { try? await app.loadProfiles() }
        }
    }
}
