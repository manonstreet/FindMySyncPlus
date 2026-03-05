import Foundation

extension Error {
    /// Heuristic check for macOS permission-denied errors (Full Disk Access).
    var isPermissionDenied: Bool {
        let ns = self as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 257 { return true }
        let desc = localizedDescription
        return desc.localizedCaseInsensitiveContains("operation not permitted")
            || desc.localizedCaseInsensitiveContains("permission")
    }
}
