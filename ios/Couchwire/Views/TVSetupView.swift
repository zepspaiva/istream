import CouchwireTVSetup
import SwiftUI

// MARK: Which TV

/// First run, after the add-ons: find the TV (or pick its brand), then put Couchwire on it.
struct TVSetupStartView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationStack {
            PickTVView { ip, name in app.useTV(ip: ip, name: name) }
                .navigationTitle("Your TV")
        }
    }
}

/// The TVs on this network, by brand, and the brands to pick from by hand. `onFinished` takes the TV that's ready.
struct PickTVView: View {
    let onFinished: (_ ip: String, _ name: String?) -> Void
    @State private var scanner = TVScanner()

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "tv").font(.largeTitle).foregroundStyle(.tint)
                    Text("Put Couchwire on your TV").font(.title2.bold())
                    Text("Couchwire needs its own app on the TV. Pick your TV and the phone installs it, with a few steps on the TV first.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            Section {
                ForEach(scanner.supported) { device in
                    NavigationLink {
                        LGSetupView(ip: device.ip, name: device.name, onFinished: onFinished)
                    } label: {
                        DeviceRow(device: device)
                    }
                }
                ForEach(scanner.others) { device in
                    DeviceRow(device: device)
                }
                if scanner.devices.isEmpty || scanner.sweeping {
                    HStack {
                        ProgressView()
                        Text(scanner.sweeping ? "Looking at every address on this Wi-Fi…" : "Looking…")
                            .foregroundStyle(.secondary)
                    }
                } else if !scanner.swept {
                    Button("Look again, more thoroughly") { Task { await scanner.sweep() } }
                }
            } header: {
                Text("On this Wi-Fi")
            } footer: {
                if scanner.swept && scanner.supported.isEmpty {
                    Text("No LG TV answered. Is it on, and on the same Wi-Fi as this phone? You can also pick LG below and type its address.")
                }
            }

            Section {
                ForEach(TVBrand.allCases) { brand in
                    NavigationLink {
                        if brand.isSupported {
                            LGAddressView(onFinished: onFinished)
                        } else {
                            UnsupportedBrandView(brand: brand)
                        }
                    } label: {
                        HStack {
                            Text(brand.name)
                            Spacer()
                            if !brand.isSupported {
                                Text("Not yet").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Or choose its brand")
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .task {
            // Bonjour finds most TVs in a second or two; when it hasn't found an LG, look at every address too.
            try? await Task.sleep(for: .seconds(3))
            if scanner.supported.isEmpty { await scanner.sweep() }
        }
    }
}

private struct DeviceRow: View {
    let device: TVScanner.Device

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .foregroundStyle(device.brand?.isSupported == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).lineLimit(1)
                Text([device.brand?.name, device.model, device.ip].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if device.brand?.isSupported != true {
                Text("Not supported yet").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// LG picked by hand: its address.
struct LGAddressView: View {
    let onFinished: (_ ip: String, _ name: String?) -> Void
    @State private var address = ""

    private var ip: String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil ? trimmed : nil
    }

    var body: some View {
        Form {
            Section {
                TextField("192.168.1.34", text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                if let ip {
                    NavigationLink("Next") { LGSetupView(ip: ip, name: nil, onFinished: onFinished) }
                }
            } header: {
                Text("The TV's address")
            } footer: {
                Text("On the TV: Settings › General › Network › Wi-Fi (or Wired) › Advanced. The Developer Mode app (next step) shows it too.")
            }
        }
        .navigationTitle("LG TV")
    }
}

struct UnsupportedBrandView: View {
    let brand: TVBrand

    var body: some View {
        ContentUnavailableView {
            Label("\(brand.name) isn't supported yet", systemImage: "tv.slash")
        } description: {
            Text("Couchwire works with LG TVs (webOS 3 or newer) for now. Other TVs are on the list.")
        }
        .navigationTitle(brand.name)
    }
}

// MARK: Installing on an LG TV

/// The steps on the TV (LG Developer Mode), checked off as the TV turns them on, then the install.
struct LGSetupView: View {
    let ip: String
    let name: String?
    /// The button at the end: "Continue" during the first run, "Done" from the TV tab.
    var finishTitle = "Continue"
    let onFinished: (_ ip: String, _ name: String?) -> Void
    @State private var setup: LGSetup

    init(ip: String, name: String?, finishTitle: String = "Continue",
         onFinished: @escaping (_ ip: String, _ name: String?) -> Void) {
        self.ip = ip
        self.name = name
        self.finishTitle = finishTitle
        self.onFinished = onFinished
        _setup = State(initialValue: LGSetup(ip: ip))
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(name ?? "LG TV", value: ip)
                if let info = setup.tvInfo {
                    LabeledContent("Model", value: info.modelName ?? "—")
                    LabeledContent("webOS", value: info.sdkVersion ?? "—")
                }
            }

            if setup.phase == .done {
                Section {
                    Label("Couchwire is on the TV", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Next, the TV asks to allow this phone: say yes with its remote.").foregroundStyle(.secondary)
                    Button(finishTitle) { onFinished(ip, name) }.bold()
                }
            } else {
                stepsSections
                installSection
                Section {
                    Button("Couchwire is already on this TV") { onFinished(ip, name) }
                }
            }
        }
        .navigationTitle("Set up the TV")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { setup.watch() }
        .onDisappear { setup.stopWatching() }
    }

    @ViewBuilder private var stepsSections: some View {
        Section {
            SetupStep(number: 1, title: "Make a free LG developer account", done: setup.devMode == true) {
                Text("On this phone or a computer. It's free; LG asks for it to turn on Developer Mode.")
                Link("webostv.developer.lge.com", destination: URL(string: "https://webostv.developer.lge.com/login")!)
            }
            SetupStep(number: 2, title: "Install Developer Mode on the TV", done: setup.devMode == true) {
                Text("On the TV, open the LG Content Store (Apps), search for “Developer Mode” and install it.")
            }
            SetupStep(number: 3, title: "Turn on Dev Mode Status", done: setup.devMode == true) {
                Text("Open Developer Mode on the TV, sign in with your LG developer account and turn on Dev Mode Status. The TV restarts.")
            }
            if !setup.hasKey {
                SetupStep(number: 4, title: "Turn on Key Server", done: setup.keyServer == true) {
                    Text("Open Developer Mode again and turn on Key Server. It shows a passphrase: you'll type it below.")
                }
            }
        } header: {
            Text("On the TV")
        } footer: {
            Text(statusLine)
        }
    }

    @ViewBuilder private var installSection: some View {
        Section {
            if !setup.hasKey {
                TextField("Passphrase shown on the TV", text: $setup.passphrase)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .font(.body.monospaced())
            }
            Button { setup.install() } label: {
                HStack {
                    Text(setup.hasKey ? "Install or update Couchwire on the TV" : "Install Couchwire on the TV")
                    Spacer()
                    if setup.isWorking { ProgressView() }
                }
            }
            .disabled(!setup.canInstall)
            switch setup.phase {
            case .working(let text):
                Text(text).foregroundStyle(.secondary)
            case .copying(let part):
                ProgressView("Copying the app to the TV…", value: part)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            default:
                EmptyView()
            }
        } footer: {
            Text("The phone installs the app over the home network, the way LG's own developer tools do. Developer Mode lasts about 40 days; press EXTEND in the Developer Mode app now and then.")
        }
    }

    private var statusLine: String {
        switch (setup.devMode, setup.keyServer) {
        case (nil, _): return "Checking the TV…"
        case (false?, _): return "Developer Mode isn't on yet (or the TV is off)."
        case (true?, true?): return "Developer Mode and Key Server are on."
        case (true?, _): return setup.hasKey ? "Developer Mode is on." : "Developer Mode is on. Key Server isn't, yet."
        }
    }
}

private struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                content.font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
