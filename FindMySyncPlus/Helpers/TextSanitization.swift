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
