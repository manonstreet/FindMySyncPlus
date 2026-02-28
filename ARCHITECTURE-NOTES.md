# Architecture Notes

Findings from a code review of the stable, production build. The app has been running for weeks with flat memory — none of these are crash or leak sources. Listed roughly by severity.

---

## Architecturally Incorrect

### 1. Blocking I/O and crypto on the main actor

**Files:** `Decryptor.swift:161`, `AppModel.swift:299`

`readEncryptedPayload` calls `Data(contentsOf: fileURL)` (a blocking syscall) and `decryptPayload` runs ChaChaPoly decryption synchronously. Both are invoked from `readAndParseCaches`, which runs on `@MainActor` because `AppModel` is `@MainActor final class` and all its methods inherit that isolation.

This is technically wrong — blocking the main thread is always incorrect regardless of how fast the operation completes in practice. For small cache files and 5-minute intervals it produces no perceptible hitch, but it would become visible if the cache grows or the disk is slow.

**Fix direction:** Mark `readEncryptedPayload` and `decryptPayload` as `nonisolated` and call `readAndParseCaches` from a `Task.detached` or via `await withCheckedContinuation` off the main actor.

**Status:** Resolved — Decryptor converted to actor (2026-02-27).

---

### 2. `Decryptor` has unguarded mutable state

**File:** `Decryptor.swift:122-125`

`Decryptor` is a plain `final class` (non-isolated) with `private var fmipKey: SymmetricKey?`. Its mutating methods (`ensureFMIPKey`, `decryptPayload`, `invalidateKey`) are all currently reached through `@MainActor` paths, so there is no actual data race today. But the compiler cannot enforce this — nothing prevents `Decryptor` from being shared across actors in the future without warning.

**Fix direction:** Make `Decryptor` an `actor`. The `post` and `testEndpointAuthentication` methods are already `async`, so actor-hopping would be transparent at call sites.

**Status:** Resolved — Decryptor converted to actor (2026-02-27).

---

## Minor / Design-Level

### 3. Extra HTTP round-trip on every scheduled run

**File:** `AppModel.swift:496-568`

`runPreflight` runs three sequential checks before each run: (1) cache readability — verifies at least one enabled cache file can be read, catching a revoked Full Disk Access before any network calls; (2) key validity — actually decrypts the payload to confirm the decryption key is still good; (3) endpoint auth — a GET to `/api/` confirming HA is reachable and credentials are valid.

The auth GET is intentional. Without it, a downed HA instance or expired token produces N failed POST attempts in the logs — one per tracked device. With preflight, the run aborts after one clean diagnostic message. Each of the three checks also produces a distinct log entry, making it straightforward to distinguish FDA issues from key issues from auth issues.

The "sticky auth known good flag" approach would save one GET per run but would lose the clean failure mode and require careful invalidation logic. Given the app runs every 5+ minutes against a local network endpoint, the trade-off does not favour the optimisation.

**Status:** Intentional design — not a bug.

---

### 4. `DateFormatter` allocated on every SwiftUI render

**File:** `FindMySyncPlusApp.swift:460-464`

`nextRunMenuText` is a computed property that constructs a `DateFormatter()` inline. `DateFormatter` is one of the more expensive Foundation objects to allocate. Since this property is read during every body render of the menu bar extra, it creates unnecessary allocations. Should be a `static let` or a `@State` constant.

---

### 5. N full `AppStorage` writes per run

**File:** `SettingsStore.swift:194-210`, `AppModel.swift:433`

`buildPlanAndLog` calls `settings.updateAlias(..., lastSeenName:)` once per tracked device. Each call JSON-encodes the entire alias array and writes it to `UserDefaults`. With a small alias count this is imperceptible, but it is O(N) full-serialize writes where one deferred batch write at the end of the run would suffice.

---

### 6. `InstallCoordinator` initialization via hidden background view

**File:** `FindMySyncPlusApp.swift:352-377`, `559-561`

App startup logic (binding models, optionally starting the scheduler, optionally opening the main window) is triggered from the `.onAppear` of a `Color.clear.frame(0,0)` view attached as a `.background` on the menu bar icon image. This is a workaround for `MenuBarExtra` having no direct `onFinishLaunching` hook in SwiftUI. It works reliably because the `MenuBarExtra` renders immediately on launch, but the dependency is non-obvious — a future refactor that moves the icon view could inadvertently break initialization.

**Fix direction:** Not urgent. If the app ever moves to a more complex scene structure, migrating the initialization to `AppDelegate.applicationDidFinishLaunching` (where `@StateObject` values can be accessed via `NSApp`'s scene environment) would be cleaner.
