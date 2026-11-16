import SwiftUI

// MARK: On screen

/// "Back up to a file" and "Restore from a file". The first run shows only the restore.
struct BackupSection: View {
    @Environment(AppModel.self) private var app
    var canExport = true

    @State private var exporting = false
    @State private var importing = false
    @State private var document: BackupDocument?
    @State private var fileName = ""
    @State private var message: String?

    var body: some View {
        Section {
            if canExport {
                Button("Back up to a file") { prepareExport() }
            }
            Button("Restore from a file") { importing = true }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        } header: {
            Text("Backup")
        } footer: {
            Text(canExport
                 ? "Saves your add-ons, library and watch progress in one file, in Files, iCloud Drive or anywhere you choose. Add-on addresses can include personal keys, so keep the file private. Restoring adds what's missing and keeps what's already here."
                 : "Moving from another phone? Restore the backup file you made there.")
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: fileName) { result in
            switch result {
            case .success: message = "Backup saved."
            case let .failure(error):
                if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            switch result {
            case let .success(url): restore(from: url)
            case let .failure(error): message = error.localizedDescription
            }
        }
    }

    private func prepareExport() {
        let backup = app.store.makeBackup()
        do {
            document = BackupDocument(data: try backup.encoded())
            fileName = backup.suggestedFileName
            message = nil
            exporting = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore(from url: URL) {
        message = restoreBackup(from: url, into: app)
    }
}

/// Reads a backup file picked in Files and merges it in. Returns what to tell the person.
@MainActor
func restoreBackup(from url: URL, into app: AppModel) -> String {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
        guard let data = try? Data(contentsOf: url) else { throw BackupError.unreadable }
        let backup = try CouchwireBackup.decode(data)
        return app.restore(backup).text
    } catch {
        return error.localizedDescription
    }
}
