import Foundation

// Stremio's add-on protocol (the stremio-addon-sdk docs, protocol.md): an add-on is a
// base URL; `<base>/manifest.json` says what it serves, and `<base>/<resource>/<type>/<id>[/<extra>].json` serves it.
// Add-ons are written by many people: everything here is read leniently, and anything odd is skipped, never fatal.

typealias JSON = [String: Any]

func string(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty else { return nil }
    return text
}

func strings(_ value: Any?) -> [String] {
    if let list = value as? [Any] {
        var seen = Set<String>()
        return list.compactMap { $0 as? String }.filter { seen.insert($0).inserted }
    }
    if let text = value as? String {
        var seen = Set<String>()
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    return []
}

func int(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
}

/// An add-on's address as people paste it ("…/manifest.json", trailing slashes, stremio:// links).
public struct AddonURL: Hashable, Sendable {
    public let base: String
    public var manifest: String { base + "/manifest.json" }

    public init?(_ raw: String) {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasPrefix("stremio://") { url = "https://" + url.dropFirst("stremio://".count) }
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/manifest.json") { url.removeLast("/manifest.json".count) }
        guard let parsed = URL(string: url), let scheme = parsed.scheme, ["http", "https"].contains(scheme),
              parsed.host != nil else { return nil }
        base = url
    }
}

public struct CatalogDef: Hashable, Sendable {
    public let type: String
    public let id: String
    public let name: String?
    public let genres: [String]
    /// Extras the catalog takes (search, genre, skip).
    public let extras: [String]
    /// Extras it can't do without: such a catalog isn't a home row.
    public let required: [String]

    public func supports(_ extra: String) -> Bool { extras.contains(extra) }
}

public struct ResourceDef: Hashable, Sendable {
    public let name: String
    public let types: [String]?
    public let idPrefixes: [String]?
}

public struct Manifest: Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let logo: String?
    public let types: [String]
    public let idPrefixes: [String]?
    public let resources: [ResourceDef]
    public let catalogs: [CatalogDef]
    public let configurationRequired: Bool

    static let resourceNames: Set<String> = ["catalog", "meta", "stream", "subtitles", "addon_catalog"]

    /// Nil when it isn't a manifest (no id, no name, nothing it serves).
    public init?(json: Any) {
        guard let object = json as? JSON, let id = string(object["id"]), let name = string(object["name"]) else {
            return nil
        }
        var resources: [ResourceDef] = []
        for entry in object["resources"] as? [Any] ?? [] {
            if let name = entry as? String, Self.resourceNames.contains(name) {
                resources.append(ResourceDef(name: name, types: nil, idPrefixes: nil))
            } else if let record = entry as? JSON, let name = string(record["name"]), Self.resourceNames.contains(name) {
                resources.append(ResourceDef(name: name, types: strings(record["types"]),
                                             idPrefixes: record["idPrefixes"] == nil ? nil : strings(record["idPrefixes"])))
            }
        }
        guard !resources.isEmpty else { return nil }
        var catalogs: [CatalogDef] = []
        for entry in object["catalogs"] as? [Any] ?? [] {
            guard let record = entry as? JSON, let type = string(record["type"]), let catalogId = string(record["id"]) else {
                continue
            }
            let extra = (record["extra"] as? [Any] ?? []).compactMap { $0 as? JSON }
            let extras = record["extraSupported"] != nil ? strings(record["extraSupported"])
                : extra.compactMap { string($0["name"]) }
            let required = record["extraRequired"] != nil ? strings(record["extraRequired"])
                : extra.filter { $0["isRequired"] as? Bool == true }.compactMap { string($0["name"]) }
            var genres = strings(record["genres"])
            if genres.isEmpty, let genre = extra.first(where: { string($0["name"]) == "genre" }) {
                genres = strings(genre["options"])
            }
            catalogs.append(CatalogDef(type: type, id: catalogId, name: string(record["name"]), genres: genres,
                                       extras: extras, required: required))
        }
        let hints = object["behaviorHints"] as? JSON
        self.id = id
        self.name = name
        version = string(object["version"]) ?? "0.0.0"
        description = string(object["description"])
        logo = string(object["logo"])
        types = strings(object["types"])
        idPrefixes = object["idPrefixes"] == nil ? nil : strings(object["idPrefixes"])
        self.resources = resources
        self.catalogs = catalogs
        configurationRequired = hints?["configurationRequired"] as? Bool == true
    }

    /// Whether it answers `resource` for this type and id (its types and id prefixes, per resource or overall).
    public func serves(_ resource: String, type: String, id: String) -> Bool {
        guard let match = resources.first(where: { $0.name == resource }) else { return false }
        let types = match.types ?? self.types
        let prefixes = match.idPrefixes ?? idPrefixes
        if !types.isEmpty && !types.contains(type) { return false }
        if let prefixes, !prefixes.isEmpty, !prefixes.contains(where: { id.hasPrefix($0) }) { return false }
        return true
    }
}

/// An add-on someone added: its address and what its manifest said.
public struct InstalledAddon: Hashable, Sendable, Identifiable {
    public let url: AddonURL
    public let manifest: Manifest

    public var id: String { url.base }
    public var name: String { manifest.name }
}
