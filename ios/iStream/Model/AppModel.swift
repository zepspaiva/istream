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
