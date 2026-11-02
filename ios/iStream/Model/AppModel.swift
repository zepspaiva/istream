import FreeMyTVKit
import Observation
import SwiftUI

/// Who and where: the Pi's address, the signed-in account, this device's profile. Decides which screen shows.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case connect      // no Pi yet
        case signIn       // the Pi answers, nobody signed in
        case pickProfile  // signed in, "Who's watching?"
        case ready
    }

    private enum Key {
        static let piAddress = "piAddress"
        static let profileId = "profileId"
        static let askProfile = "askProfileOnLaunch"
        static let email = "email"
        static let token = "piToken"
        static let tvIP = "tvIP"
        static let tvKey = "tvClientKey"
    }

    private let defaults = UserDefaults.standard

    private(set) var phase: Phase = .connect
    private(set) var piURL: URL?
    private(set) var token: String?
    private(set) var profileId: Int?
    private(set) var email: String?
    var profiles: [Profile] = []

    /// A shared iPad asks "Who's watching?" every time the app opens; a phone remembers.
    var askProfileOnLaunch: Bool {
        get { askProfile }
        set {
            askProfile = newValue
            defaults.set(newValue, forKey: Key.askProfile)
        }
    }
    private var askProfile = false

    let playback = Playback()
    /// The phone's own line to the TV (M2): playing, pausing, seeking, audio and subtitles.
    let tv = TVConnection()
    /// The Lock Screen and Dynamic Island's Now Playing (M3).
    let liveActivity = LiveActivityController()
    /// The Now Playing sheet.
    var showNowPlaying = false

    @ObservationIgnored private var progressSavedAt = Date.distantPast
    @ObservationIgnored private var lastScreen = "home"

    init() {
        let defaults = UserDefaults.standard
        piURL = defaults.string(forKey: Key.piAddress).flatMap(PiClient.address(from:))
        token = Keychain.read(Key.token)
        email = defaults.string(forKey: Key.email)
        let saved = defaults.integer(forKey: Key.profileId)
        profileId = saved > 0 ? saved : nil
        if defaults.object(forKey: Key.askProfile) == nil {
            askProfile = UIDevice.current.userInterfaceIdiom == .pad
        } else {
            askProfile = defaults.bool(forKey: Key.askProfile)
        }
        playback.app = self
        tv.ip = defaults.string(forKey: Key.tvIP)
        tv.clientKey = Keychain.read(Key.tvKey)
        phase = Self.phase(piURL: piURL, token: token, profileId: askProfile ? nil : profileId)
    }

    private static func phase(piURL: URL?, token: String?, profileId: Int?) -> Phase {
        if piURL == nil { return .connect }
        if token == nil { return .signIn }
        if profileId == nil { return .pickProfile }
        return .ready
    }

    var profile: Profile? { profiles.first { $0.id == profileId } }

    /// The API as this device: its token and profile.
    var client: PiClient {
        PiClient(base: piURL ?? URL(string: "http://192.168.1.35:3000")!, token: token, profile: profileId)
    }

    // MARK: The TV

    /// The app came to the front: talk to the TV (the Pi says where it is and lends its pairing, once).
    func becameActive() {
        guard phase == .ready else { return }
        tv.onNewKey = { key in Keychain.write(Key.tvKey, key) }
        tv.onState = { [weak self] state in
            self?.noteProgress(state)
            self?.liveActivity.update(state)
        }
        if tv.ip == nil || tv.clientKey == nil {
            Task {
                if let pairing = try? await client.tvPairing() {
                    tv.ip = pairing.ip
                    defaults.set(pairing.ip, forKey: Key.tvIP)
                    if tv.clientKey == nil, let key = pairing.clientKey {
                        tv.clientKey = key
                        Keychain.write(Key.tvKey, key)
                    }
                }
                tv.start()
            }
        } else {
            tv.start()
        }
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

    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The TV's place goes to the account every 30 s while playing, and when it pauses or stops.
    private func noteProgress(_ state: PlayerState) {
        defer { lastScreen = state.screen }
        guard let ref = state.ref, state.duration > 60, state.screen == "playing" || state.screen == "paused" else {
            return
        }
        let changed = state.screen != lastScreen && (state.screen == "paused" || lastScreen == "playing")
        guard changed || (state.isPlaying && Date().timeIntervalSince(progressSavedAt) > 30) else { return }
        progressSavedAt = Date()
        let client = client
        Task {
            try? await client.saveProgress(ref, season: state.season, episode: state.episode,
                                           position: state.position, duration: state.duration)
        }
    }

    // MARK: Steps

    func connect(to text: String) async throws {
        guard let url = PiClient.address(from: text) else {
            throw PiError(status: 0, message: "That doesn't look like an address")
        }
        let info = try await PiClient(base: url).info()
        guard info.name == "istream" else {
            throw PiError(status: 0, message: "Something answered there, but it isn't the iStream Pi")
        }
        piURL = url
        defaults.set(url.absoluteString, forKey: Key.piAddress)
        phase = token == nil ? .signIn : .pickProfile
    }

    func signIn(email: String, password: String) async throws {
        let result = try await client.login(email: email, password: password)
        token = result.token
        Keychain.write(Key.token, result.token)
        self.email = result.user.email ?? email
        defaults.set(self.email, forKey: Key.email)
        phase = .pickProfile
    }

    func loadProfiles() async throws {
        do {
            profiles = try await client.profiles()
        } catch let error as PiError where error.needsSignIn {
            signedOut()
            throw error
        }
    }

    func choose(_ profile: Profile) {
        profileId = profile.id
        defaults.set(profile.id, forKey: Key.profileId)
        phase = .ready
    }

    func switchProfile() {
        phase = .pickProfile
    }

    func changePi() {
        phase = .connect
    }

    func signOut() async {
        try? await client.logout()
        signedOut()
    }

    /// The Pi no longer knows this token (or the person signed out).
    func signedOut() {
        token = nil
        Keychain.write(Key.token, nil)
        profiles = []
        phase = piURL == nil ? .connect : .signIn
    }

    /// Any call that comes back "sign in first" lands here.
    func handle(_ error: Error) {
        if let error = error as? PiError, error.needsSignIn {
            signedOut()
        }
    }
}
