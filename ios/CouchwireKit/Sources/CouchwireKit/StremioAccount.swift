import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bringing someone's add-ons over from their Stremio account (api.strem.io, what Stremio's own apps use). The
/// password goes to Stremio only, once; nothing of the account is kept.
public enum StremioAccount {
    private static let api = URL(string: "https://api.strem.io/api/")!

    /// The add-on addresses in the account, in its order (Stremio's built-in "local" add-ons left out).
    public static func addons(email: String, password: String, session: URLSession = .shared) async throws -> [AddonURL] {
        let login = try await call("login", ["type": "Login", "email": email, "password": password], session: session)
        guard let authKey = login["authKey"] as? String else {
            throw AddonError(message: "Stremio didn't accept that email and password")
        }
        defer {
            Task { _ = try? await call("logout", ["type": "Logout", "authKey": authKey], session: session) }
        }
        let collection = try await call("addonCollectionGet",
                                        ["type": "AddonCollectionGet", "authKey": authKey, "update": true],
                                        session: session)
        let entries = collection["addons"] as? [Any] ?? []
        return entries.compactMap { entry in
            guard let item = entry as? [String: Any], let transport = item["transportUrl"] as? String,
                  transport.hasPrefix("http") else { return nil }
            return AddonURL(transport)
        }
    }

    private static func call(_ method: String, _ body: [String: Any], session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: api.appendingPathComponent(method), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let error = object["error"] as? [String: Any] {
            throw AddonError(message: (error["message"] as? String) ?? "Stremio said no")
        }
        if let error = object["error"] as? String { throw AddonError(message: error) }
        return object["result"] as? [String: Any] ?? [:]
    }
}
