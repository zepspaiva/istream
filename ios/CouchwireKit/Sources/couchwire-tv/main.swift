import CouchwireTVSetup
import Foundation

// The first test of the TV setup, on the Mac: can Swift (Citadel) log in to the TV over SSH and talk to it, the way
// the phone will? Same code as the app.
//
//   cd ios/CouchwireKit
//   swift run couchwire-tv 192.168.1.34                       # log in, say what the TV is
//   swift run couchwire-tv 192.168.1.34 --install ../../tv/Couchwire-webos.ipk
//   swift run couchwire-tv 192.168.1.34 --key ~/.ssh/freemytv_webos_192_168_1_34
//
// The key: --key, or the one install.py already unlocked (~/.ssh/freemytv_webos_<IP>), or else it's fetched from the
// TV's Key Server and you type the passphrase the Developer Mode app shows (not stored; the unlocked key is kept in
// ~/.ssh/couchwire_webos_<IP>).

let args = Array(CommandLine.arguments.dropFirst())
guard let ip = args.first, ip.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil else {
    print("Usage: swift run couchwire-tv <TV IP> [--key PATH] [--install PATH.ipk] [--uninstall]")
    exit(2)
}
func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return (args[index + 1] as NSString).expandingTildeInPath
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let underscored = ip.replacingOccurrences(of: ".", with: "_")
let savedKey = "\(home)/.ssh/couchwire_webos_\(underscored)"
let installPyKey = "\(home)/.ssh/freemytv_webos_\(underscored)"

func step(_ text: String) { print("• " + text) }

do {
    let api = await PortProbe.isOpen(ip, 3000)
    let ssh = await PortProbe.isOpen(ip, 9922)
    let keyServer = await PortProbe.isOpen(ip, 9991)
    func word(_ open: Bool) -> String { open ? "open" : "closed" }
    step("Ports: remote API 3000 \(word(api)), SSH 9922 \(word(ssh)), Key Server 9991 \(word(keyServer))")

    let key: String
    if let path = option("--key") ?? [savedKey, installPyKey].first(where: { FileManager.default.fileExists(atPath: $0) }) {
        step("Key: \(path)")
        key = try DevModeKey.unlock(String(contentsOfFile: path, encoding: .utf8), passphrase: "")
    } else {
        step("Getting the TV's key from http://\(ip):9991/webos_rsa")
        let locked = try await DevModeKey.download(from: ip)
        guard let typed = getpass("Passphrase shown in Developer Mode on the TV: ") else { exit(1) }
        key = try DevModeKey.unlock(locked, passphrase: String(cString: typed).trimmingCharacters(in: .whitespaces))
        FileManager.default.createFile(atPath: savedKey, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        step("Unlocked; kept in \(savedKey)")
    }

    step("Logging in (prisoner@\(ip):9922)")
    let tv = try await WebOSDevMode.connect(ip: ip, key: key)
    let uname = try await tv.run("uname -a")
    step("Logged in. uname: " + uname.trimmingCharacters(in: .whitespacesAndNewlines))
    let info = await tv.systemInfo()
    step("TV: model \(info.modelName ?? "?"), webOS SDK \(info.sdkVersion ?? "?"), 4K \(info.isUHD.map { $0 ? "yes" : "no" } ?? "?")")

    let appId = "com.zeeh.couchwire.tv"
    if args.contains("--uninstall") {
        try await tv.uninstall(appId: appId)
        step("Removed \(appId).")
    } else if let path = option("--install") {
        let ipk = try Data(contentsOf: URL(fileURLWithPath: path))
        step("Installing \(path) (\(ipk.count / 1024) KB)")
        try await tv.install(ipk: ipk, hdIPK: nil, appId: appId) { progress in
            switch progress {
            case .connecting: break
            case .copying(let part): if part == 0 || part >= 1 { step(part == 0 ? "Copying…" : "Copied") }
            case .installing: step("Installing…")
            case .opening: step("Opening…")
            case .done: step("Installed and open on the TV.")
            }
        }
    }
    await tv.close()
} catch {
    print("✗ \(error.localizedDescription)")
    print("  (\(error))")
    exit(1)
}
