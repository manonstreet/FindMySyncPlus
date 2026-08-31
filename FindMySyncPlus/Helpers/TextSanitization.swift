import Foundation
import CryptoKit

// Normalize and sanitize alias strings for persistence
// - Allows letters, numbers, hyphen, underscore
// - Collapses other characters to single hyphens
// - Trims leading/trailing hyphens
// - Caps length at 48
// - Returns "device" if result is empty
@inline(__always)
func slugifyAlias(_ raw: String, maxLen: Int = 48) -> String {
    // Fold accents and width; lowercased
    let folded = raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
    var out: [Character] = []
    out.reserveCapacity(min(folded.count, maxLen))
    var prevDash = false

    for ch in folded {
        if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
            out.append(ch)
            prevDash = false
        } else {
            if !prevDash {
                out.append("-")
                prevDash = true
            }
        }
        if out.count >= maxLen { break }
    }

    // Trim leading/trailing hyphens without O(n) shifts
    var start = out.startIndex
    while start < out.endIndex, out[start] == "-" { start = out.index(after: start) }
    if start == out.endIndex { return "device" }
    var end = out.index(before: out.endIndex)
    while end > start, out[end] == "-" { end = out.index(before: end) }

    let trimmed = String(out[start...end])
    return trimmed.isEmpty ? "device" : trimmed
}

// Convert an alias-derived ID into the object part of a Home Assistant entity
// ID. HA allows only [a-z0-9_] there, while `slugifyAlias` above deliberately
// permits hyphens — so this is a second, narrower conversion, applied ONLY to
// `default_entity_id`.
//
// HA would sanitize the value anyway: `default_entity_id` is validated as a
// plain string, and `async_generate_entity_id` slugifies its input. Doing it
// here means the value we publish is the entity ID HA will actually create, so
// what we log is what the user will see.
//
// It must never be applied to `unique_id`: that is the entity registry's
// identity key, and changing it re-registers every existing user's entities as
// duplicates, orphaning the originals.
@inline(__always)
func haSlug(_ raw: String) -> String {
    var out: [Character] = []
    var prevUnderscore = false

    for ch in raw.lowercased() {
        // `isLetter` alone is true for "é", which HA would reject.
        if ch.isASCII && (ch.isLetter || ch.isNumber) {
            out.append(ch)
            prevUnderscore = false
        } else if !prevUnderscore {
            out.append("_")
            prevUnderscore = true
        }
    }

    while out.first == "_" { out.removeFirst() }
    while out.last == "_" { out.removeLast() }

    return out.isEmpty ? "device" : String(out)
}

// General-purpose nullish string normalization used when extracting IDs from dictionaries
@inline(__always)
func normalizeID(_ any: Any?) -> String? {
    guard var s = any as? String else { return nil }
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }
    let t = s.lowercased()
    if t == "$null" || t == "null" || t == "<null>" || t == "(null)" || t == "none" { return nil }
    return s
}

// Convenient helper for optional strings
extension Optional where Wrapped == String {
    var nonNullish: String? {
        guard let s = self else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty || ["$null", "null", "<null>", "(null)", "none"].contains(t) { return nil }
        return s
    }
}

// Normalize UUID-like strings to lowercase hex
extension String {
    private static let hexSet: Set<Character> = Set("0123456789abcdef")
    func normalized() -> String {
        let lower = self.lowercased()
        return String(lower.lazy.filter { Self.hexSet.contains($0) })
    }
}

// Derive a stable, MAC-shaped identifier from an alias.
// Uses SHA-256 over the alias bytes and formats the first 6 bytes as aa:bb:cc:dd:ee:ff.
@inline(__always)
func macFromAlias(_ alias: String) -> String {
    let data = Data(alias.utf8)
    let digest = SHA256.hash(data: data)
    let firstSix = Array(digest.prefix(6))
    let parts = firstSix.map { String(format: "%02x", $0) }
    return parts.joined(separator: ":")
}
