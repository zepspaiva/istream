import CouchwireKit
import Network
import Observation
import SwiftUI

// MARK: First run: the add-ons

struct AddonsSetupView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "puzzlepiece.extension.fill").font(.largeTitle).foregroundStyle(.tint)
                        Text("Bring your add-ons").font(.title2.bold())
                        Text("Couchwire shows what your add-ons offer: catalogs, details and streams. Bring them from your Stremio account, or add one by its address.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                AddAddonSections()
            }
            .navigationTitle("Couchwire")
        }
    }
}

/// Importing from Stremio, and adding one by its address: used by the first run and the add-ons screen.
struct AddAddonSections: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var address = ""
    @State private var working: String?
    @State private var message: String?

    var body: some View {
        Section {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textContentType(.password)
            Button { importFromStremio() } label: {
                HStack {
                    Text("Import from Stremio")
                    Spacer()
                    if working == "stremio" { ProgressView() }
                }
            }
            .disabled(working != nil || email.isEmpty || password.isEmpty)
        } header: {
            Text("From your Stremio account")
        } footer: {
            Text("Your password goes to Stremio once, to read your add-on list; Couchwire doesn't keep it.")
        }
        Section {
            TextField("https://…/manifest.json", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button { addByAddress() } label: {
                HStack {
                    Text("Add")
                    Spacer()
                    if working == "address" { ProgressView() }
                }
            }
            .disabled(working != nil || address.isEmpty)
        } header: {
            Text("By its address")
        }
        if let message {
            Section { Text(message).foregroundStyle(.secondary) }
        }
    }

    private func importFromStremio() {
        working = "stremio"
        message = nil
        Task {
            do {
                let urls = try await StremioAccount.addons(email: email.trimmingCharacters(in: .whitespaces),
                                                           password: password)
                password = ""
                if urls.isEmpty {
                    message = "That account has no add-ons to bring."
                } else {
                    app.addAddons(urls)
                    message = "Added \(urls.count) add-ons."
                }
            } catch {
                message = error.localizedDescription
            }
            working = nil
        }
    }

    private func addByAddress() {
        guard let url = AddonURL(address) else {
            message = "That doesn't look like an add-on's address."
            return
        }
        working = "address"
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
            working = nil
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
            AddAddonSections()
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
                Section {
                    LabeledContent("Version", value: Bundle.main.appVersion)
                }
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
