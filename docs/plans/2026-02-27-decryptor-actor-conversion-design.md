# Design: Decryptor Actor Conversion

**Date:** 2026-02-27
**Addresses:** Architecture Notes items #1 (blocking I/O on main actor) and #2 (unguarded mutable state in Decryptor)
**Approach:** Convert `Decryptor` from `final class` to `actor`

---

## Problem

`AppModel` is `@MainActor final class`. All its methods — including `readAndParseCaches` and `runPreflight` — inherit main actor isolation. This means two synchronous blocking operations run on the main thread on every scheduled run:

1. `Data(contentsOf: fileURL)` in `readEncryptedPayload` — blocking disk I/O syscall
2. `ChaChaPoly.open(...)` in `decryptPayload` — synchronous CPU-bound crypto

Additionally, `Decryptor.fmipKey: SymmetricKey?` is mutable state on a plain `final class` with no compiler-enforced isolation. It is currently safe only because all callers happen to be `@MainActor`, but nothing prevents future misuse.

---

## Solution

Convert `actor Decryptor`. Swift assigns actors their own executor on the cooperative thread pool. All actor-isolated methods automatically execute off the main thread. The compiler enforces isolation of `fmipKey`.

This single change fixes both architecture issues simultaneously.

---

## Decryptor Method Changes

| Method | Change |
|--------|--------|
| `fmipKey: SymmetricKey?` | Stays `private var` — now actor-protected |
| `ensureFMIPKey(logger:)` | Actor-isolated — callers add `await` |
| `invalidateKey()` | Actor-isolated — callers add `await` |
| `readEncryptedPayload(from:logger:)` | Actor-isolated — callers add `await`; `DispatchQueue.main.async` → `Task { @MainActor in }` |
| `decryptPayload(_:logger:)` | Actor-isolated — callers add `await` |
| `parseDeviceArray(_:)` | Marked `nonisolated` — pure function, no state access |
| `extractSymmetricKey(from:)` | Stays `static` — no change |
| `post(...)` | Marked `nonisolated @MainActor` — doesn't touch `fmipKey` |
| `testEndpointAuthentication(settings:)` | Marked `nonisolated @MainActor` — doesn't touch `fmipKey` |

---

## AppModel Call Site Changes

`readAndParseCaches` becomes `async throws`. All other changes are mechanical `await` additions:

- `await decryptor.ensureFMIPKey(logger:)` in `_runOnceAsync`
- `await decryptor.readEncryptedPayload(from:logger:)` in `runPreflight` and `readAndParseCaches`
- `await decryptor.decryptPayload(_:logger:)` in `runPreflight` and `readAndParseCaches`
- `try await readAndParseCaches(...)` in `_runOnceAsync`
- `await decryptor.invalidateKey()` wherever called

`_runOnceAsync` is already `async` — absorbs these additions with no further structural change.

---

## Testing Strategy

### Tier 1 — XCTest Unit Tests (CI-safe)

New file: `FindMySyncPlusTests/DecryptorTests.swift`

| Test | Verifies |
|------|----------|
| `testParseDeviceArray_validDevice` | Known input → correct `DevicePoint` fields |
| `testParseDeviceArray_skipsNoLocation` | Device without location is dropped |
| `testParseDeviceArray_emptyArray` | Empty input → empty output, no crash |
| `testBatteryFromStatus_stringValues` | `"full"` → 1.0, `"low"` → 0.25, `"verylow"` → 0.1, etc. |
| `testBatteryFromStatus_numericValues` | `0.5` → 0.5, `75` (Int) → 0.75 |
| `testExtractSymmetricKey_base64String` | Valid 32-byte base64 → `Data` |
| `testExtractSymmetricKey_nestedDict` | `["symmetricKey": base64]` → `Data` |
| `testDecryptPayload_roundTrip` | Synthesize key → ChaChaPoly-seal fake plist → load key → `decryptPayload` → verify output |
| `testDecryptPayload_wrongKey` | Wrong key → `.failure(.incorrectKey)` |
| `testReadEncryptedPayload_syntheticFile` | Write valid outer plist to temp file → `.success(data)` |
| `testReadEncryptedPayload_missingFile` | Nonexistent file → `.failure(.fileReadError)` |
| `testDecryptorRunsOffMainThread` | Call `decryptPayload` from main actor, assert `Thread.isMainThread == false` inside |

### Tier 2 — In-App Diagnostics (Debug builds only)

A **Run Diagnostics** button added to the existing General settings pane, hidden in Release builds via `#if DEBUG`.

Steps run on tap:
1. `ensureFMIPKey` — logs success or key-not-found
2. `readEncryptedPayload` on each enabled cache — logs readable/unreadable per file
3. `decryptPayload` — logs device count or error
4. Reports pass/fail per step to `LogStore`

Results surface in the existing Status log view. No new views or models required.

---

## Constraints

- Project uses `SWIFT_STRICT_CONCURRENCY = complete` (Swift 6 mode) — all actor boundary crossings must satisfy the compiler
- `LogStore` and `SettingsStore` are `@MainActor` — calls to them from within actor-isolated methods must use `Task { @MainActor in }` or be deferred to call sites on the main actor
- No new dependencies
- `post()` and `testEndpointAuthentication()` remain `@MainActor` — they are `nonisolated` on the actor and their behaviour is unchanged
