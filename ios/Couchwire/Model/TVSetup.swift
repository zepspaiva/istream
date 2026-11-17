import CouchwireTVSetup
import Darwin
import Foundation
import Network
import Observation

// MARK: The brands

/// TV makers the setup knows by name. Only LG (webOS) is supported for now.
enum TVBrand: String, CaseIterable, Identifiable {
    case lg, samsung, sony, philips, tcl, hisense, panasonic, googleTV, appleTV, other

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lg: "LG"
        case .samsung: "Samsung"
        case .sony: "Sony"
        case .philips: "Philips"
        case .tcl: "TCL"
        case .hisense: "Hisense"
        case .panasonic: "Panasonic"
        case .googleTV: "Google TV or Android TV"
        case .appleTV: "Apple TV"
        case .other: "Another brand"
        }
    }

    var isSupported: Bool { self == .lg }

    /// From what a device says about itself on the network (its AirPlay name, maker and model).
    static func guess(name: String, manufacturer: String?, model: String?) -> TVBrand? {
        let text = [name, manufacturer ?? "", model ?? ""].joined(separator: " ").lowercased()
        if text.contains("lg electronics") || text.contains("[lg]") || text.contains("webos") || text.hasPrefix("lg ") {
            return .lg
        }
        if text.contains("samsung") { return .samsung }
        if text.contains("sony") || text.contains("bravia") { return .sony }
        if text.contains("philips") { return .philips }
        if text.contains("tcl") { return .tcl }
        if text.contains("hisense") || text.contains("vidaa") { return .hisense }
        if text.contains("panasonic") { return .panasonic }
        if (model ?? "").hasPrefix("AppleTV") { return .appleTV }
        return nil
    }

    /// Apple devices that aren't TVs (Macs, HomePods, iPhones) also announce AirPlay: left out of the list.
    static func isNotATV(model: String?) -> Bool {
        guard let model else { return false }
        return ["Mac", "iMac", "AudioAccessory", "iPhone", "iPad", "Book", "MacBook", "AirPort"].contains { model.hasPrefix($0) }
    }
}

// MARK: Finding TVs

/// TVs on the home network. Two ways, neither needing Apple's multicast entitlement (a free developer account can't
/// have it): Bonjour browsing for AirPlay, which most TVs since 2019 announce, with their maker and model; and, for
/// TVs that don't, a sweep of this network's addresses for LG's remote API port (3000).
@MainActor @Observable
final class TVScanner {
    struct Device: Identifiable, Hashable {
        let ip: String
        var name: String
        var brand: TVBrand?
        var model: String?
        var id: String { ip }
    }

    private(set) var devices: [Device] = []
    private(set) var sweeping = false
    private(set) var swept = false
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolving: [NWConnection] = []
    @ObservationIgnored private var seen: Set<String> = []

    var supported: [Device] { devices.filter { $0.brand?.isSupported == true } }
    var others: [Device] { devices.filter { $0.brand?.isSupported != true } }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: nil), using: .tcp)
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
            guard case let .service(name, _, _, _) = result.endpoint, !seen.contains(name) else { continue }
            seen.insert(name)
            var manufacturer: String?
            var model: String?
            if case let .bonjour(txt) = result.metadata {
                manufacturer = txt["manufacturer"]
                model = txt["model"]
            }
            if TVBrand.isNotATV(model: model) { continue }
            let brand = TVBrand.guess(name: name, manufacturer: manufacturer, model: model)
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state, let path = connection?.currentPath,
                      case let .hostPort(host, _)? = path.remoteEndpoint, case let .ipv4(address) = host else { return }
                let ip = "\(address)".components(separatedBy: "%").first ?? "\(address)"
                Task { @MainActor in
                    self?.add(Device(ip: ip, name: name, brand: brand, model: model))
                    connection?.cancel()
                }
            }
            connection.start(queue: .main)
            resolving.append(connection)
        }
    }

    private func add(_ device: Device) {
        if let index = devices.firstIndex(where: { $0.ip == device.ip }) {
            // AirPlay knows the name; the sweep only the address.
            if devices[index].brand == nil || device.brand != nil { devices[index] = device }
        } else {
            devices.append(device)
        }
    }

    /// Every address on this Wi-Fi (up to 254 of them), asked whether LG's remote API answers.
    func sweep() async {
        guard !sweeping, let network = LocalNetwork.current() else { return }
        sweeping = true
        defer {
            sweeping = false
            swept = true
        }
        let hosts = network.hosts.filter { $0 != network.address }
        for batch in stride(from: 0, to: hosts.count, by: 32).map({ Array(hosts[$0..<min($0 + 32, hosts.count)]) }) {
            let open = await withTaskGroup(of: String?.self) { group in
                for host in batch {
                    group.addTask { await PortProbe.isOpen(host, 3000, timeout: 1) ? host : nil }
                }
                var found: [String] = []
                for await host in group { if let host { found.append(host) } }
                return found
            }
            for ip in open where !devices.contains(where: { $0.ip == ip }) {
                add(Device(ip: ip, name: "LG TV", brand: .lg, model: nil))
            }
        }
    }
}

/// This phone's Wi-Fi address and the addresses around it.
struct LocalNetwork {
    let address: String
    let hosts: [String]

    static func current() -> LocalNetwork? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == "en0", let addr = entry.ifa_addr, let mask = entry.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            // Bigger networks than a /24: look at the /24 the phone is in.
            netmask = max(netmask, 0xFFFF_FF00)
            let base = ip & netmask
            let count = Int(~netmask)
            guard count > 1 else { return nil }
            let hosts = (1..<count).map { dotted(base + UInt32($0)) }
            return LocalNetwork(address: dotted(ip), hosts: hosts)
        }
        return nil
    }

    private static func dotted(_ value: UInt32) -> String {
        "\(value >> 24 & 0xff).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }
}

// MARK: Installing on an LG TV

/// One LG TV's setup: watches what Developer Mode has turned on, then installs the TV app over SSH.
@MainActor @Observable
final class LGSetup {
    enum Phase: Equatable {
        case idle
        case working(String)
        case copying(Double)
        case done
        case failed(String)
    }

    let ip: String
    /// SSH answers: Developer Mode is on.
    private(set) var devMode: Bool?
    /// The TV's Key Server answers (needed only the first time, to get the key).
    private(set) var keyServer: Bool?
    private(set) var phase: Phase = .idle
    private(set) var tvInfo: WebOSDevMode.SystemInfo?
    /// The passphrase the Developer Mode app shows. Used once to unlock the key, never stored.
    var passphrase = ""

    @ObservationIgnored private var watcher: Task<Void, Never>?

    init(ip: String) { self.ip = ip }

    var hasKey: Bool { Self.savedKey(ip) != nil }
    var isWorking: Bool {
        switch phase {
        case .working, .copying: true
        default: false
        }
    }
    var canInstall: Bool {
        devMode == true && !isWorking && (hasKey || (keyServer == true && passphrase.count >= 4))
    }

    // The unlocked key, per TV address, in the Keychain.
    static func savedKey(_ ip: String) -> String? { Keychain.read("webosKey." + ip) }
    static func saveKey(_ ip: String, _ key: String?) { Keychain.write("webosKey." + ip, key) }

    /// Checks the TV's ports every two seconds while the screen is open.
    func watch() {
        guard watcher == nil else { return }
        let ip = ip
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                async let ssh = PortProbe.isOpen(ip, UInt16(WebOSDevMode.port))
                async let keys = PortProbe.isOpen(ip, 9991)
                let (sshOpen, keysOpen) = await (ssh, keys)
                guard let self else { return }
                self.devMode = sshOpen
                self.keyServer = keysOpen
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    func install() {
        guard !isWorking else { return }
        Task { await runInstall() }
    }

    private func runInstall() async {
        guard let ipk = Self.bundled("Couchwire-tv") else {
            phase = .failed("This build of the app doesn't have the TV app inside. Build it again in Xcode (the \"Build the TV app\" step needs Python 3).")
            return
        }
        do {
            var key = Self.savedKey(ip)
            if key == nil {
                phase = .working("Getting the TV's key…")
                let locked = try await DevModeKey.download(from: ip)
                key = try DevModeKey.unlock(locked, passphrase: passphrase.trimmingCharacters(in: .whitespaces))
                Self.saveKey(ip, key)
                passphrase = ""
            }
            phase = .working("Connecting to the TV…")
            let tv: WebOSDevMode
            do {
                tv = try await WebOSDevMode.connect(ip: ip, key: key!)
            } catch {
                // The key may be from before Developer Mode was turned off and on again: get a fresh one next time.
                Self.saveKey(ip, nil)
                throw error
            }
            defer { Task { await tv.close() } }
            tvInfo = await tv.systemInfo()
            try await tv.install(ipk: ipk, hdIPK: Self.bundled("Couchwire-tv-hd"), appId: TVConnection.appId) { step in
                Task { @MainActor [weak self] in self?.show(step) }
            }
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func show(_ step: WebOSDevMode.Step) {
        guard phase != .done else { return }
        switch step {
        case .connecting: phase = .working("Connecting to the TV…")
        case .copying(let part): phase = .copying(part)
        case .installing: phase = .working("Installing on the TV…")
        case .opening: phase = .working("Opening Couchwire on the TV…")
        case .done: break
        }
    }

    /// The TV app, built into the phone app by the "Build the TV app" step (project.yml).
    private static func bundled(_ name: String) -> Data? {
        Bundle.main.url(forResource: name, withExtension: "ipk").flatMap { try? Data(contentsOf: $0) }
    }
}
