# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FindMySyncPlus** is a macOS menu bar app (macOS 15+ only) that decrypts Apple Find My cache files and publishes device, item, and friend locations to Home Assistant via `device_tracker.see`. It is a pure Swift/SwiftUI/AppKit project built entirely in Xcode — no package manager, no scripts.

## Build & Run

Open and build in Xcode:
```
open FindMySyncPlus.xcodeproj
```

There is no CLI build or test runner script. All development happens through Xcode. For signing, enable "Automatically manage signing" and set a personal Team under Signing & Capabilities.

## Linting

SwiftLint is configured via `.swiftlint.yml`. Run locally with `swiftlint lint` or `swiftlint lint --fix` for auto-corrections. A GitHub Action runs lint on PRs and pushes to `main`/`v1.1-beta`.

## Architecture

### App Lifecycle (`FindMySyncPlusApp.swift`)
The app starts as an `.accessory` (menu bar–only) process and switches to `.regular` when a window opens. `PolicyController` manages `NSApplication.activationPolicy`. `AppDelegate` + `WindowManager` handle window lifecycle. `WindowCoordinator` is a singleton that other code uses to open auxiliary windows.

Three `@ObservableObject` singletons are shared via the environment:
- **`AppModel`** — scheduler, UI state, counters; owns `SyncEngine`
- **`SettingsStore`** — all user configuration (`@AppStorage` + Keychain)
- **`LogStore`** — in-memory log buffer (capped at 5000 entries)

### Data Flow
```
AppModel (@MainActor)          — scheduler, UI state, counters
    │
    └─▶ SyncEngine (@MainActor)   — orchestrates one sync run
            ├─▶ CacheDecryptor (actor)        — FMIP cache decrypt + parse
            │     Devices.data / Items.data (ChaChaPoly via CryptoKit)
            │     FriendCacheData.data (FMF contact names, ChaChaPoly)
            ├─▶ LocalStorageDecryptor (actor)  — LocalStorage.db decrypt + query
            │     AES-256-CBC page-level keystream XOR
            └─▶ HAClient (enum, static)        — HTTP posting + auth testing
                  POST → Home Assistant device_tracker.see
```

Requires Full Disk Access to read the Find My cache. `FindMyRefresher.swift` can launch the Find My app to force a cache refresh.

### Three Decryption Keys
| Keychain key | Source file | Crypto | Enables |
|---|---|---|---|
| `fmipSymmetricKey` | `FMIPDataManager.bplist` | ChaChaPoly | Devices + Items |
| `fmfKey` | `FMFDataManager.bplist` | ChaChaPoly | Friend display names |
| `localStorageKey` | `LocalStorage.key` (raw 32 bytes) | AES-256-CBC keystream XOR | Friend locations |

### Key Files
| File | Role |
|------|------|
| `Models/AppModel.swift` | Scheduler, UI state, counters; delegates sync to `SyncEngine` |
| `SyncEngine.swift` | Orchestrates one sync run: decrypt, plan, post; owns decryptor instances |
| `CacheDecryptor.swift` | `actor` — FMIP cache decryption (ChaChaPoly), FMF contact name lookup |
| `LocalStorageDecryptor.swift` | `actor` — LocalStorage.db decryption (AES-256-CBC page-level), SQLite friend query |
| `HAClient.swift` | `enum` (caseless namespace) — HTTP posting to HA + endpoint auth testing |
| `Models/SettingsStore.swift` | All persisted config; Keychain wrappers for auth token and 3 decryption keys |
| `Models/DeviceAlias.swift` | Alias↔UUID mapping model |
| `Models/LogStore.swift` | Logging with levels; consumed by StatusView |
| `Views/DeviceManagerView.swift` | Assign aliases to discovered UUIDs; source badges (Device/Item/Friend) |
| `Views/AccessSettingsView.swift` | HA endpoint, auth token, segmented key management UI with bulk import |
| `Helpers/Keychain.swift` | Generic SecItem wrapper; keys: `fmipSymmetricKey`, `fmfKey`, `localStorageKey` |

### Device Identity
`dev_id` is `findmy_<alias>` (lowercased slug). UUIDs for AirTags and iPhone/Apple Watch rotate; `auto-learn UUIDs` in `SyncEngine` updates `DeviceAlias` when a known device is seen under a new UUID. Dry-run mode reads and decrypts but never POSTs to HA.

## Testing

30 unit tests across three test files: `CacheDecryptorTests` (ChaChaPoly round-trips), `TextSanitizationTests` (slugify, normalizeID), `LocalStorageDecryptorTests` (AES-CBC page decryption). Tests use synthetic data — no real Find My files required. Run via Xcode (Cmd+U) or xcodebuild test.

## Conventions
- `AppModel`, `SettingsStore`, `LogStore` are `@MainActor final class` using `@Published` + Combine for reactivity.
- `SyncEngine` is `@MainActor final class` — orchestrates the full sync pipeline (preflight, decrypt, plan, post). Owns `CacheDecryptor` and `LocalStorageDecryptor` instances. Bound to `AppModel` via `bind()`.
- `CacheDecryptor` is an `actor` — disk I/O and ChaChaPoly decryption run on the actor's cooperative thread pool executor, not the main thread. `fmipKey` and `fmfKey` isolation is compiler-enforced. `parseDeviceArray` and `extractSymmetricKey` are `nonisolated` (pure functions).
- `LocalStorageDecryptor` is an `actor` — AES-256-CBC page-level decryption of LocalStorage.db with WAL support. `decryptPage`, `parseWAL`, `buildDecryptedDB` are `nonisolated` (pure crypto). Friends are deduplicated against family devices using DSID (Apple's universal person ID).
- `HAClient` is a caseless `enum` with `@MainActor static` methods for HTTP posting and endpoint auth testing.
- Keychain reads/writes are synchronous wrappers around `Security.framework`.
- Transient network errors do not mutate `endpointAuthStatus`; only explicit 401/403 marks it invalid.
- `LSUIElement = YES` in Info.plist hides the Dock icon by default; `PolicyController` shows it when a window is open.
- `SettingsStore.batchUpdateLastSeenNames` batches all alias name updates into a single UserDefaults write per run cycle.
