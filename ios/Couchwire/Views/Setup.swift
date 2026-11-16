import CouchwireKit
import Network
import Observation
import SwiftUI

// MARK: First run: welcome, then the add-ons

struct AddonsSetupView: View {
    var body: some View {
        NavigationStack {
            WelcomeView()
        }
    }
}

/// The first screen: what Couchwire is, then "Get started" (add an add-on) or "Restore from a backup".
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "sofa.fill").font(.system(size: 44)).foregroundStyle(.tint)
                    Text("Welcome to Couchwire").font(.largeTitle.bold())
                    Text("Your phone, instead of the TV remote.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 20) {
                    WelcomePoint(systemImage: "hand.tap",
                                 title: "Pick on your phone",
                                 text: "Browse and choose what to watch on your iPhone or iPad, not with the arrow keys.")
                    WelcomePoint(systemImage: "tv",
                                 title: "Your LG TV plays it",
                                 text: "The TV wakes up, opens Couchwire and starts playing. No inputs, no menus.")
                    WelcomePoint(systemImage: "playpause",
                                 title: "Your phone is the remote",
                                 text: "Pause, skip, and change audio or subtitles from the app, the Lock Screen or the Dynamic Island.")
                    WelcomePoint(systemImage: "puzzlepiece.extension",
                                 title: "You bring the add-ons",
                                 text: "Couchwire comes with nothing to watch. It shows what the add-ons you add offer: catalogs, details and streams. You add them by their address.")
                }
                Text("Everything stays on this phone. There's no account to make.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                NavigationLink {
                    FirstAddonView()
                } label: {
                    Text("Get started").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Restore from a backup") { importing = true }
                    .controlSize(.large)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            switch result {
            case let .success(url): message = restoreBackup(from: url, into: app)
            case let .failure(error): message = error.localizedDescription
            }
        }
    }
}

private struct WelcomePoint: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// After "Get started": add the first add-on by its address, or restore a backup.
struct FirstAddonView: View {
    var body: some View {
        Form {
            Section {
                Text("Paste the address of an add-on you use. It usually ends in manifest.json. You can add more, and change their order, later in Settings.")
                    .foregroundStyle(.secondary)
            }
            AddAddonSection()
            BackupSection(canExport: false)
        }
        .navigationTitle("Your first add-on")
    }
}

/// Adding an add-on by its address: used by the first run and the add-ons screen.
struct AddAddonSection: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section {
            TextField("https://…/manifest.json", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button { addByAddress() } label: {
                HStack {
                    Text("Add")
                    Spacer()
                    if working { ProgressView() }
                }
            }
            .disabled(working || address.isEmpty)
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        } header: {
            Text("Add by its address")
        } footer: {
            Text("An address can include a personal key. Couchwire keeps it on this phone only.")
        }
    }

    private func addByAddress() {
        guard let url = AddonURL(address) else {
            message = "That doesn't look like an add-on's address."
            return
        }
        working = true
        message = nil
        Task {
            do {
                let manifest = try await app.content.engine.manifest(url, fresh: true)
                app.addAddons([url])
                address = ""
                message = "Added \(manifest.name)."
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: The add-ons, later

struct AddonsView: View {
    @Environment(AppModel.self) private var app
    @State private var addons: [InstalledAddon] = []
    @State private var urls: [AddonURL] = []

    var body: some View {
        Form {
            Section {
                ForEach(urls, id: \.base) { url in
                    let addon = addons.first { $0.url == url }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(addon?.name ?? url.base).lineLimit(1)
                        Text(addon.map(summary) ?? "Not answering").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { app.removeAddon(urls[index]) }
                    urls.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    urls.move(fromOffsets: from, toOffset: to)
                    app.moveAddons(urls)
                }
            } header: {
                Text("Your add-ons")
            } footer: {
                Text("The order is the order on Home, and which add-on's details win.")
            }
            AddAddonSection()
        }
        .navigationTitle("Add-ons")
        .toolbar { EditButton() }
        .task(id: app.store.addonURLs.map(\.base)) {
            urls = app.store.addonURLs
            addons = await app.content.addons()
        }
    }

    private func summary(_ addon: InstalledAddon) -> String {
        let serves = addon.manifest.resources.map(\.name).map { name in
            switch name {
            case "catalog": return "catalogs"
            case "meta": return "details"
            case "stream": return "streams"
            case "subtitles": return "subtitles"
            default: return name
            }
        }
        return serves.joined(separator: ", ")
    }
}

// MARK: Finding the TV

/// LG TVs announce themselves for AirPlay on the home network: listed here by name, with their address.
@MainActor @Observable
final class TVFinder {
    struct Found: Identifiable, Hashable {
        let name: String
        let ip: String
        var id: String { ip }
    }

    private(set) var found: [Found] = []
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolving: [NWConnection] = []

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_airplay._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.forEach { $0.cancel() }
        resolving = []
    }

    private func resolve(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, !found.contains(where: { $0.name == name })
            else { continue }
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state, let path = connection?.currentPath,
                      case let .hostPort(host, _)? = path.remoteEndpoint, case let .ipv4(address) = host else { return }
                let ip = "\(address)".components(separatedBy: "%").first ?? "\(address)"
                Task { @MainActor in
                    guard let self, !self.found.contains(where: { $0.ip == ip }) else { return }
                    self.found.append(Found(name: name, ip: ip))
                    connection?.cancel()
                }
            }
            connection.start(queue: .main)
            resolving.append(connection)
        }
    }
}

struct FindTVView: View {
    @Environment(AppModel.self) private var app
    @State private var finder = TVFinder()
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "tv").font(.largeTitle).foregroundStyle(.tint)
                        Text("Your TV").font(.title2.bold())
                        Text("Pick your LG TV. The first time, the TV asks to allow this phone: say yes with its remote.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                Section("On this network") {
                    if finder.found.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(finder.found) { tv in
                        Button { app.useTV(ip: tv.ip, name: tv.name) } label: {
                            LabeledContent(tv.name, value: tv.ip)
                        }
                    }
                }
                Section {
                    TextField("192.168.1.34", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    Button("Use this address") {
                        app.useTV(ip: address.trimmingCharacters(in: .whitespaces), name: nil)
                    }
                    .disabled(address.isEmpty)
                } header: {
                    Text("Or its address")
                } footer: {
                    Text("On the TV: Settings › General › Network › Wi-Fi (or Wired) › Advanced.")
                }
            }
            .navigationTitle("Couchwire")
            .onAppear { finder.start() }
            .onDisappear { finder.stop() }
        }
    }
}

// MARK: Settings

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingErase = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("TV") {
                    LabeledContent(app.tvName ?? "LG TV", value: app.tv.ip ?? "—")
                    LabeledContent("Phone remote", value: statusText)
                    Button("Use another TV", role: .destructive) {
                        dismiss()
                        app.forgetTV()
                    }
                }
                Section {
                    NavigationLink("Add-ons") { AddonsView() }
                    Picker("Stream quality", selection: $app.preferredQuality) {
                        Text("Automatic").tag("auto")
                        Text("4K").tag("4K")
                        Text("1080p").tag("1080p")
                        Text("720p").tag("720p")
                    }
                } footer: {
                    Text("Automatic keeps your add-ons' order and skips streams whose sound may not play on the TV.")
                }
                BackupSection()
                Section {
                    Button("Erase everything", role: .destructive) { confirmingErase = true }
                } footer: {
                    Text("Deletes your add-ons, library, watch progress, the paired TV and your settings from this device, and goes back to the welcome page. Back up to a file first if you might want them again.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                }
            }
            .alert("Erase everything?", isPresented: $confirmingErase) {
                Button("Erase everything", role: .destructive) {
                    dismiss()
                    app.eraseEverything()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your add-ons, library, watch progress and TV pairing will be deleted from this phone. This can't be undone, unless you have a backup file.")
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var statusText: String {
        switch app.tv.status {
        case .connected: return "Connected"
        case .waitingForApp: return "Opens with Couchwire on the TV"
        case .needsPairing: return "Allow this phone on the TV"
        case .off: return "TV off"
        case .connecting: return "Connecting…"
        case .unknown: return "—"
        }
    }
}
