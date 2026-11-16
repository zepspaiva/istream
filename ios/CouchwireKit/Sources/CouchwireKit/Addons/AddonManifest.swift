import Foundation

// Written from Stremio's public add-on protocol documentation (github.com/Stremio/stremio-addon-sdk, docs/protocol.md
// and docs/api/responses/manifest.md). An add-on is an address: `<address>/manifest.json` describes it, and
// `<address>/<resource>/<type>/<id>[/<extra>].json` answers requests.

/// Where an add-on lives, as people paste it: with or without `/manifest.json`, or as a `stremio://` link.
public struct AddonURL: Hashable, Sendable {
    /// The address without `/manifest.json`. Requests are built on it, and it is what the app saves.
    public let base: String

    public var manifest: String { base + "/manifest.json" }

    public init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("stremio://") {
            text = "https://" + text.dropFirst("stremio://".count)
        } else if !text.contains("://") {
            text = "https://" + text
        }
        guard var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, host.contains(".") || host.contains(":") || host == "localhost"
        else { return nil }

        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/manifest.json") { path.removeLast("/manifest.json".count) }
        while path.hasSuffix("/") { path.removeLast() }

        parts.scheme = scheme
        parts.percentEncodedPath = path
        parts.query = nil
        parts.fragment = nil
        guard let address = parts.string else { return nil }
        base = address
    }
}

/// One of the add-on's catalogs: a list of titles it can give, maybe searchable or filterable by genre.
public struct CatalogDef: Hashable, Sendable {
    public let type: String
    public let id: String
    public let name: String?
    /// The genres it can be filtered by, when it offers a list.
    public let genres: [String]
    /// The extra properties it accepts (`search`, `genre`, `skip`, ...).
    public let extras: [String]
    /// The extra properties it can't do without: a catalog that requires `search` only answers searches.
    public let required: [String]

    public func supports(_ extra: String) -> Bool { extras.contains(extra) }

    /// A plain feed: it can be listed without a search or anything else.
    var isFeed: Bool { required.isEmpty }

    init?(json: JSONObject) {
        guard let type = json.text("type"), let id = json.text("id") else { return nil }
        self.type = type
        self.id = id
        name = json.text("name")

        var extras: [String] = []
        var required: [String] = []
        var genres: [String] = []
        for extra in json.objects("extra") {
            guard let name = extra.text("name") else { continue }
            extras.append(name)
            if extra.flag("isRequired") { required.append(name) }
            if name == "genre" { genres = extra.texts("options") }
        }
        // The older, short form of the same thing.
        for name in json.texts("extraSupported") where !extras.contains(name) { extras.append(name) }
        for name in json.texts("extraRequired") where !required.contains(name) {
            required.append(name)
            if !extras.contains(name) { extras.append(name) }
        }
        if genres.isEmpty { genres = json.texts("genres") }

        self.extras = extras
        self.required = required
        self.genres = genres
    }
}

/// A resource the add-on answers (`catalog`, `meta`, `stream`, `subtitles`, ...). When the manifest lists it as a
/// plain name, `types` and `idPrefixes` are nil and the manifest's own apply.
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
    /// The add-on says it needs settings first. An address that already carries them still has this set.
    public let configurationRequired: Bool

    public init?(json: Any) {
        guard let json = json as? JSONObject, let id = json.text("id") else { return nil }
        self.id = id
        name = json.text("name") ?? id
        version = json.text("version") ?? "0.0.0"
        description = json.text("description")
        logo = json.text("logo")
        types = json.texts("types")
        let prefixes = json.texts("idPrefixes")
        idPrefixes = prefixes.isEmpty ? nil : prefixes

        var resources: [ResourceDef] = []
        for entry in json["resources"] as? [Any] ?? [] {
            if let name = entry as? String, !name.isEmpty {
                resources.append(ResourceDef(name: name, types: nil, idPrefixes: nil))
            } else if let object = entry as? JSONObject, let name = object.text("name") {
                let types = object.texts("types")
                let prefixes = object.texts("idPrefixes")
                resources.append(ResourceDef(name: name, types: types.isEmpty ? nil : types,
                                             idPrefixes: prefixes.isEmpty ? nil : prefixes))
            }
        }
        catalogs = json.objects("catalogs").compactMap(CatalogDef.init(json:))
        // A manifest with catalogs but no resources still means it answers catalog requests.
        if !resources.contains(where: { $0.name == "catalog" }) && !catalogs.isEmpty {
            resources.append(ResourceDef(name: "catalog", types: nil, idPrefixes: nil))
        }
        self.resources = resources
        configurationRequired = json.object("behaviorHints")?.flag("configurationRequired") ?? false
    }

    /// Whether to ask this add-on for `resource` of a title of `type` with this `id`. A resource given in full
    /// (with its own types) uses its own id prefixes, where none means every id; a plain name uses the manifest's.
    public func serves(_ resource: String, type: String, id: String) -> Bool {
        resources.contains { def in
            guard def.name == resource else { return false }
            let types = def.types ?? self.types
            guard types.contains(type) else { return false }
            let prefixes = def.types == nil ? (def.idPrefixes ?? idPrefixes) : def.idPrefixes
            guard let prefixes, !prefixes.isEmpty else { return true }
            return prefixes.contains { id.hasPrefix($0) }
        }
    }
}

/// An add-on the person added, with its manifest loaded.
public struct InstalledAddon: Hashable, Sendable, Identifiable {
    public let url: AddonURL
    public let manifest: Manifest

    public var id: String { url.base }
    public var name: String { manifest.name }

    public init(url: AddonURL, manifest: Manifest) {
        self.url = url
        self.manifest = manifest
    }
}
