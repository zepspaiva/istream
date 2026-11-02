import FreeMyTVKit
import SwiftUI

// MARK: Finding the Pi

struct ConnectView: View {
    @Environment(AppModel.self) private var app
    @State private var address = "192.168.1.35"
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.35", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { connect() }
                } header: {
                    Text("The Pi's address")
                } footer: {
                    Text("The Raspberry Pi on your home Wi-Fi that runs iStream. The phone needs to be on the same Wi-Fi.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                Section {
                    Button { connect() } label: {
                        HStack {
                            Text("Connect")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || address.isEmpty)
                }
            }
            .navigationTitle("iStream")
        }
    }

    private func connect() {
        working = true
        error = nil
        Task {
            do {
                try await app.connect(to: address)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: Signing in

struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { signIn() }
                } header: {
                    Text("Your Nuvio account")
                } footer: {
                    Text("Your profiles, add-ons and library come from it. The password goes to the Pi, which signs in to Nuvio for you.")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                }
                Section {
                    Button { signIn() } label: {
                        HStack {
                            Text("Sign in")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }
                    .disabled(working || email.isEmpty || password.isEmpty)
                }
                Section {
                    Button("Use a different Pi") { app.changePi() }
                }
            }
            .navigationTitle("Sign in")
            .onAppear { email = app.email ?? email }
        }
    }

    private func signIn() {
        guard !email.isEmpty, !password.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                try await app.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: Who's watching?

struct ProfilePickerView: View {
    @Environment(AppModel.self) private var app
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    Text("Who's watching?").font(.largeTitle.bold()).padding(.top, 40)
                    if loading && app.profiles.isEmpty {
                        ProgressView()
                    } else if let error, app.profiles.isEmpty {
                        ErrorState(message: error) { await load() }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 24)], spacing: 28) {
                            ForEach(app.profiles) { profile in
                                Button { app.choose(profile) } label: {
                                    VStack(spacing: 10) {
                                        ProfileBadge(profile: profile, size: 96)
                                            .overlay {
                                                if profile.id == app.profileId {
                                                    Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                                                }
                                            }
                                        Text(profile.name).font(.headline).lineLimit(1)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign out", role: .destructive) { Task { await app.signOut() } }
                        Button("Use a different Pi") { app.changePi() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        do {
            try await app.loadProfiles()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
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
                Section("Watching as") {
                    HStack(spacing: 12) {
                        ProfileBadge(profile: app.profile, size: 36)
                        Text(app.profile?.name ?? "Profile \(app.profileId ?? 0)").font(.headline)
                    }
                    Button("Switch profile") {
                        dismiss()
                        app.switchProfile()
                    }
                    Toggle("Ask who's watching when the app opens", isOn: $app.askProfileOnLaunch)
                }
                Section("Account") {
                    LabeledContent("Nuvio", value: app.email ?? "—")
                    Button("Sign out", role: .destructive) {
                        dismiss()
                        Task { await app.signOut() }
                    }
                }
                Section("Pi") {
                    LabeledContent("Address", value: app.piURL?.absoluteString ?? "—")
                    Button("Use a different Pi") {
                        dismiss()
                        app.changePi()
                    }
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
}
