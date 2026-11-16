import Foundation

// Add-ons are written by many different people, so what they send is read loosely: a field that is missing, empty or
// of an unexpected type counts as absent, and never fails the rest of the answer.

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    /// A non-empty string (numbers are accepted and written out).
    func text(_ key: String) -> String? {
        switch self[key] {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as Int:
            return String(value)
        case let value as Double:
            return value == value.rounded() ? String(Int(value)) : String(value)
        default:
            return nil
        }
    }

    /// A list of non-empty strings; a single string counts as a list of one.
    func texts(_ key: String) -> [String] {
        if let one = text(key) { return [one] }
        guard let list = self[key] as? [Any] else { return [] }
        return list.compactMap { item in
            guard let string = item as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func number(_ key: String) -> Double? {
        switch self[key] {
        case let value as Int: return Double(value)
        case let value as Double: return value
        case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    func flag(_ key: String) -> Bool {
        switch self[key] {
        case let value as Bool: return value
        case let value as String: return value.lowercased() == "true"
        default: return false
        }
    }

    func object(_ key: String) -> JSONObject? {
        self[key] as? JSONObject
    }

    func objects(_ key: String) -> [JSONObject] {
        (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
    }
}
