import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// An SSH session with an LG TV in Developer Mode: port 9922, user "prisoner", the key from DevModeKey.
/// The same steps as tv/webos/install.py: copy the .ipk to /media/developer/temp, install it with the TV's own
/// installer (luna://com.webos.appInstallService/dev/install), then open it.
public final class WebOSDevMode {
    public static let port = 9922
    public static let tempPath = "/media/developer/temp/couchwire.ipk"

    public enum Step: Sendable, Equatable {
        case connecting, copying(Double), installing, opening, done
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct SystemInfo: Sendable {
        public var modelName: String?
        public var sdkVersion: String?   // webOS version, e.g. "10.3.2" on webOS 10
        public var isUHD: Bool?
    }

    private let client: SSHClient
    public let ip: String

    private init(client: SSHClient, ip: String) {
        self.client = client
        self.ip = ip
    }

    /// Logs in. `key` is the unlocked OpenSSH text from DevModeKey.unlock.
    public static func connect(ip: String, key: String) async throws -> WebOSDevMode {
        let privateKey = try DevModeKey.privateKey(key)
        do {
            let client = try await SSHClient.connect(
                host: ip,
                port: port,
                authenticationMethod: .rsa(username: "prisoner", privateKey: privateKey),
                // The TV makes its own host key; there's nothing to check it against on first contact.
                hostKeyValidator: .acceptAnything(),
                reconnect: .never,
                // Adds ssh-rsa, diffie-hellman-group14 and aes128-ctr, which older TVs need.
                algorithms: .all,
                connectTimeout: .seconds(10)
            )
            return WebOSDevMode(client: client, ip: ip)
        } catch {
            throw Failure(message: "Couldn't log in to the TV over SSH (\(error)). Is Developer Mode still on, and is this the TV's key?")
        }
    }

    public func close() async {
        try? await client.close()
    }

    // MARK: Commands

    /// A shell command; its output (stdout and stderr together).
    @discardableResult
    public func run(_ command: String) async throws -> String {
        do {
            let buffer = try await client.executeCommand(command, mergeStreams: true)
            return String(buffer: buffer)
        } catch let failed as SSHClient.CommandFailed {
            throw Failure(message: "The TV said no to “\(command)” (exit \(failed.exitCode)).")
        }
    }

    /// A call on the TV's service bus. luna-send-pub prints nothing without a terminal, so it runs in one (as
    /// install.py's `ssh -tt`); if that comes back empty, the way without a terminal that webOS 6 wants.
    public func luna(_ uri: String, _ payload: [String: Any], replies: Int = 1, wait: Int = 20) async throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        // Older webOS ships BusyBox before 1.30, whose timeout only takes -t SECS.
        let timeout = "if timeout -t 1 true 2>/dev/null; then T='timeout -t \(wait)'; else T='timeout \(wait)'; fi; "
        let message = "\(uri) '\(json)'"
        let withTerminal = try await inTerminal(timeout + "$T luna-send-pub -n \(replies) \(message)",
                                                seconds: wait + 5)
        if withTerminal.contains("{") { return withTerminal }
        return (try? await run(timeout + "$T luna-send-pub -i \(message) </dev/null")) ?? ""
    }

    /// Runs a command in a shell with a terminal and collects what it prints until it exits.
    private func inTerminal(_ command: String, seconds: Int) async throws -> String {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "dumb", terminalCharacterWidth: 4000, terminalRowHeight: 24,
            terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: SSHTerminalModes([.ECHO: 0])
        )
        let output = Output()
        let client = client
        let work = Task {
            try await client.withPTY(request) { inbound, outbound in
                try await outbound.write(ByteBuffer(string: command + "; exit\n"))
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer): output.append(String(buffer: buffer))
                    }
                }
            }
        }
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            work.cancel()
        }
        // A non-zero exit or the timer ending it early: what it printed is still the answer.
        _ = try? await work.value
        timer.cancel()
        return output.text
    }

    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ""
        var text: String { lock.withLock { value } }
        func append(_ more: String) { lock.withLock { value += more } }
    }

    // MARK: What the TV is

    public func systemInfo() async -> SystemInfo {
        let out = (try? await luna("luna://com.webos.service.tv.systemproperty/getSystemInfo",
                                   ["keys": ["modelName", "sdkVersion", "UHD"]], wait: 5)) ?? ""
        func value(_ key: String) -> String? {
            guard let range = out.range(of: #""\#(key)"\s*:\s*"?([^",}]*)"#, options: .regularExpression) else {
                return nil
            }
            let match = String(out[range])
            return match.components(separatedBy: ":").dropFirst().joined(separator: ":")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        return SystemInfo(modelName: value("modelName"), sdkVersion: value("sdkVersion"),
                          isUHD: value("UHD").map { $0 == "true" })
    }

    // MARK: Installing

    /// Copies the package, installs it, opens it. `ipk` is the 4K build; `hdIPK` the same app at 1280 x 720 for TVs
    /// that aren't 4K (they draw apps at that size, and show a 1920 x 1080 app in the top left only).
    public func install(ipk: Data, hdIPK: Data?, appId: String, progress: @escaping @Sendable (Step) -> Void) async throws {
        var package = ipk
        if let hdIPK, await systemInfo().isUHD == false { package = hdIPK }

        progress(.copying(0))
        try await upload(package, to: Self.tempPath, progress: { progress(.copying($0)) })

        progress(.installing)
        let out = try await luna("luna://com.webos.appInstallService/dev/install",
                                 ["id": appId, "ipkUrl": Self.tempPath, "subscribe": true], replies: 30, wait: 90)
        guard out.contains("\"state\":\"installed\"") || out.contains("\"state\": \"installed\"") else {
            throw Failure(message: "The TV didn't finish installing. It said: \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400))")
        }
        _ = try? await run("rm -f \(Self.tempPath)")

        progress(.opening)
        _ = try? await luna("luna://com.webos.applicationManager/launch", ["id": appId], wait: 10)
        progress(.done)
    }

    public func uninstall(appId: String) async throws {
        let out = try await luna("luna://com.webos.appInstallService/dev/remove", ["id": appId], replies: 3, wait: 30)
        guard out.contains("\"returnValue\":true") || out.contains("\"returnValue\": true") else {
            throw Failure(message: "The TV said: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// SFTP when the TV offers it; otherwise in base64 pieces through the shell (BusyBox has base64).
    func upload(_ data: Data, to path: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = (path as NSString).deletingLastPathComponent
        _ = try? await run("mkdir -p \(folder)")
        do {
            let sftp = try await client.openSFTP()
            defer { Task { try? await sftp.close() } }
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                let piece = 256 * 1024
                var offset = 0
                while offset < data.count {
                    let end = min(offset + piece, data.count)
                    try await file.write(ByteBuffer(bytes: data[offset..<end]), at: UInt64(offset))
                    offset = end
                    progress(Double(offset) / Double(data.count))
                }
            }
        } catch {
            try await uploadThroughShell(data, to: path, progress: progress)
        }
        let size = try await run("wc -c < \(path)").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(size) == data.count else {
            throw Failure(message: "The app didn't arrive whole on the TV (\(size) of \(data.count) bytes).")
        }
    }

    private func uploadThroughShell(_ data: Data, to path: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await run(": > \(path)")
        let piece = 48 * 1024   // 64 KB of base64 per command, well under the shell's limits
        var offset = 0
        while offset < data.count {
            let end = min(offset + piece, data.count)
            let text = data[offset..<end].base64EncodedString()
            try await run("echo '\(text)' | base64 -d >> \(path)")
            offset = end
            progress(Double(offset) / Double(data.count))
        }
    }
}
