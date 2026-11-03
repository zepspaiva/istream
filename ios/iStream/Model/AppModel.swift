import FreeMyTVKit
import Observation
import SwiftUI

/// The app's state: the person's add-ons and library (on the phone), the TV, what's playing. Decides which screen
/// shows: setting up (add-ons, then the TV) or the app.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case addons   // no add-ons yet: bring them in
        case findTV   // no TV yet: find it and pair
        case ready
    }

    private enum Key {
        static let tvIP = "tvIP"
        static let tvKey = "tvClientKey"
        static let tvMACs = "tvMACs"
        static let tvName = "tvName"
        static let quality = "preferredQuality"
        // From the Pi days (M1 to M3): read once to carry the TV's wake addresses over.
        static let piAddress = "piAddress"
    }

    private let defaults = UserDefaults.standard

    private(set) var phase: Phase = .addons
    private(set) var tvName: String?

    let store: LocalStore
    let content: ContentService
    let playback = Playback()
    /// The phone's own line to the TV.
    let tv = TVConnection()
    /// The Lock Screen and Dynamic Island's Now Playing.
    let liveActivity = LiveActivityController()
    /// The Now Playing sheet.
    var showNowPlaying = false

    /// Which quality Play picks: "auto" (the add-ons' order), or 4K, 1080p, 720p.
    var preferredQuality: String {
        get { quality }
        set {
            quality = newValue
            content.preferredQuality = newValue
            defaults.set(newValue, forKey: Key.quality)
        }
    }
    private var quality = "auto"

    @ObservationIgnored private var progressSavedAt = Date.distantPast
    @ObservationIgnored private var lastScreen = "home"
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    init() {
        let defaults = UserDefaults.standard
        store = LocalStore()
        content = ContentService(store: store)
        quality = defaults.string(forKey: Key.quality) ?? "auto"
        content.preferredQuality = quality
        tv.ip = defaults.string(forKey: Key.tvIP)
        tv.clientKey = Keychain.read(Key.tvKey)
        tv.macs = defaults.stringArray(forKey: Key.tvMACs) ?? []
        tvName = defaults.string(forKey: Key.tvName)
        playback.app = self
        refreshPhase()
    }

    func refreshPhase() {
        phase = store.addonURLs.isEmpty ? .addons : tv.ip == nil ? .findTV : .ready
    }

    // MARK: Setting up

    func addAddons(_ urls: [AddonURL]) {
        store.addAddons(urls)
        content.addonsChanged()
        refreshPhase()
    }

    func removeAddon(_ url: AddonURL) {
        store.removeAddon(url)
        content.addonsChanged()
    }

    func moveAddons(_ order: [AddonURL]) {
        store.moveAddons(order)
        content.addonsChanged()
    }

    /// The TV to use from now on (its address; the pairing comes when the phone first connects).
    func useTV(ip: String, name: String?) {
        if ip != tv.ip {
            tv.stop()
            tv.clientKey = nil
            Keychain.write(Key.tvKey, nil)
            tv.macs = []
            defaults.removeObject(forKey: Key.tvMACs)
        }
        tv.ip = ip
        tvName = name
        defaults.set(ip, forKey: Key.tvIP)
        defaults.set(name, forKey: Key.tvName)
        refreshPhase()
        becameActive()
    }

    func forgetTV() {
        tv.stop()
        tv.ip = nil
        tv.clientKey = nil
        Keychain.write(Key.tvKey, nil)
        defaults.removeObject(forKey: Key.tvIP)
        refreshPhase()
    }

    // MARK: The TV

    /// The app came to the front: talk to the TV.
    func becameActive() {
        guard phase == .ready else { return }
        endBackgroundTime()
        tv.onNewKey = { key in Keychain.write(Key.tvKey, key) }
        tv.onState = { [weak self] state in
            self?.noteProgress(state)
            self?.liveActivity.update(state)
        }
        tv.onNeedSubtitle = { [weak self] url in
            guard let self else { return }
            Task {
                let cues = await self.content.cues(url)
                self.tv.sendCues(url, cues)
            }
        }
        carryOverFromPi()
        tv.start()
    }

    /// The TV's reports keep coming for a little while in the background, so a video started just before the phone
    /// was locked still fills in its Live Activity.
    func wentToBackground() {
        endBackgroundTime()
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.tv.stop()
            self?.endBackgroundTime()
        }
        Task {
            try? await Task.sleep(for: .seconds(25))
            if UIApplication.shared.applicationState == .background { tv.stop() }
            endBackgroundTime()
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The TV's place is kept every 30 s while playing, and when it pauses or stops.
    private func noteProgress(_ state: PlayerState) {
        defer { lastScreen = state.screen }
        guard state.ref != nil, state.duration > 60, state.screen == "playing" || state.screen == "paused" else {
            return
        }
        let changed = state.screen != lastScreen
        guard changed || Date().timeIntervalSince(progressSavedAt) > 30 else { return }
        progressSavedAt = Date()
        content.saveProgress(state)
    }

    /// Once, for a phone set up with the Pi: its pairing had the TV's network cards (MACs), which waking it needs.
    private func carryOverFromPi() {
        guard tv.macs.isEmpty, let address = defaults.string(forKey: Key.piAddress),
              let base = PiClient.address(from: address) else { return }
        Task {
            let client = PiClient(base: base, token: Keychain.read("piToken"))
            guard let pairing = try? await client.tvPairing(), !pairing.macs.isEmpty else { return }
            tv.macs = pairing.macs
            defaults.set(pairing.macs, forKey: Key.tvMACs)
            if tv.clientKey == nil, let key = pairing.clientKey {
                tv.clientKey = key
                Keychain.write(Key.tvKey, key)
            }
        }
    }

    /// Errors on screen; nothing to sign in to any more.
    func handle(_ error: Error) {}
}
