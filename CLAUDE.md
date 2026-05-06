# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FindMySyncPlus** is a macOS menu bar app (macOS 15+ only) that decrypts Apple Find My cache files and publishes device, item, and friend locations to Home Assistant. Supports **REST** (`device_tracker/see`) and **MQTT** (with HA auto-discovery and rich attributes) transports. It is a pure Swift/SwiftUI/AppKit project built entirely in Xcode — no package manager, no scripts.

## Build & Run

Open and build in Xcode:
```
open FindMySyncPlus.xcodeproj
```

There is no CLI build or test runner script. All development happens through Xcode. For signing, enable "Automatically manage signing" and set a personal Team under Signing & Capabilities.

## Linting

SwiftLint is configured via `.swiftlint.yml`. Run locally with `swiftlint lint` or `swiftlint lint --fix` for auto-corrections. A GitHub Action runs lint on PRs and pushes.

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
            └─▶ TransportClient (protocol)     — pluggable posting layer
                  ├─▶ RESTClient (@MainActor)  — HTTP POST to device_tracker/see
                  └─▶ MQTTClient (@MainActor)  — MQTT with HA auto-discovery
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
| `SyncEngine.swift` | Orchestrates one sync run via decomposed pipeline: `ensureKeys` → `readCaches` → `readFriends` → `enrichFriendNames` → `buildPlanAndLog` → `postAndReport`. Routes posting through `TransportClient` protocol. |
| `TransportClient.swift` | Protocol defining `post()`, `ensureConnected()`, `testConnection()` + shared `PostSummary` type |
| `HAClient.swift` | `RESTClient` — `@MainActor final class` conforming to `TransportClient`; HTTP posting + auth testing |
| `MQTTClient.swift` | `MQTTClient` — `@MainActor final class` conforming to `TransportClient`; MQTT with HA auto-discovery, rich attributes, auto-reconnect |
| `CacheDecryptor.swift` | `actor` — FMIP cache decryption (ChaChaPoly), FMF contact name lookup |
| `LocalStorageDecryptor.swift` | `actor` — LocalStorage.db decryption (AES-256-CBC page-level), SQLite friend query |
| `Models/SettingsStore.swift` | All persisted config; Keychain wrappers for auth token and 3 decryption keys |
| `Models/DevicePoint.swift` | Device location struct with `with()` copy method for safe field updates; carries `parentID` for grouped accessories (e.g. AirPods Case/Buds) |
| `Models/RichLocationAttributes.swift` | Rich location data (altitude, speed, course, motion state, location label) with Apple label decoder |
| `Models/DeviceAlias.swift` | Alias↔UUID mapping model |
| `Models/LogStore.swift` | Logging with levels; consumed by StatusView |
| `Views/DeviceManagerView.swift` | Assign aliases to discovered UUIDs; source badges (Device/Item/Friend) |
| `Views/AccessSettingsView.swift` | Transport picker, MQTT/REST config, connection test, segmented key management UI with bulk import |
| `Helpers/Keychain.swift` | Generic SecItem wrapper; keys: `fmipSymmetricKey`, `fmfKey`, `localStorageKey` |

### Device Identity
`dev_id` is `findmy_<alias>` (lowercased slug). UUIDs for AirTags and iPhone/Apple Watch rotate; `auto-learn UUIDs` in `SyncEngine` updates `DeviceAlias` when a known device is seen under a new UUID. Dry-run mode reads and decrypts but never posts to HA.

## Testing

70 unit tests across five test files: `CacheDecryptorTests` (ChaChaPoly round-trips, parentID plumbing for grouped items), `TextSanitizationTests` (slugify, normalizeID), `LocalStorageDecryptorTests` (AES-CBC page decryption, Apple location label decoding), `ModelTests` (DevicePoint.with() copy semantics, RichLocationAttributes motion state mapping, parentID preservation), `SyncEngineGroupingTests` (unaliased grouped child filter, parent location backfill from freshest child). Tests use synthetic data — no real Find My files required. Run via Xcode (Cmd+U) or xcodebuild test.

## Conventions
- `AppModel`, `SettingsStore` are `@MainActor final class` using `@Published` + Combine for reactivity. `LogStore` is `final class ... @unchecked Sendable`.
- `SyncEngine` is `@MainActor final class` — orchestrates the sync pipeline via decomposed named methods. Owns `CacheDecryptor`, `LocalStorageDecryptor`, `RESTClient`, and `MQTTClient` instances. Routes posting through a `transport` computed property that returns the active `TransportClient` based on `settings.transportMode`. Bound to `AppModel` via `bind()`.
- `TransportClient` is a `@MainActor` protocol with `post()`, `ensureConnected()`, and `testConnection()`. `RESTClient` and `MQTTClient` both conform.
- `CacheDecryptor` is an `actor` — disk I/O and ChaChaPoly decryption run on the actor's cooperative thread pool executor, not the main thread. `fmipKey` and `fmfKey` isolation is compiler-enforced. `parseDeviceArray` and `extractSymmetricKey` are `nonisolated` (pure functions).
- `LocalStorageDecryptor` is an `actor` — AES-256-CBC page-level decryption of LocalStorage.db with WAL support. `decryptPage`, `parseWAL`, `buildDecryptedDB` are `nonisolated` (pure crypto). Friends are deduplicated against family devices using DSID (Apple's universal person ID). Rich attributes from LocalStorage are merged onto FMIP family devices.
- `MQTTClient` auto-reconnects on unexpected disconnects with exponential backoff. Discovery IDs are cleared on reconnect so entities re-publish.
- Keychain reads/writes are synchronous wrappers around `Security.framework`.
- Transient network errors do not mutate `endpointAuthStatus`; only explicit 401/403 marks it invalid.
- `LSUIElement = YES` in Info.plist hides the Dock icon by default; `PolicyController` shows it when a window is open.
- `SettingsStore.batchUpdateLastSeenNames` batches all alias name updates into a single UserDefaults write per run cycle.
- MQTT is the default transport for new users. Existing REST users are preserved via a one-time migration.
- `SyncEngine` recognizes grouped accessories: items in `Items.data` whose `groupIdentifier` matches a `Devices.data` parent's `baUUID` get `parentID` set on their `DevicePoint`. Parent group locations are backfilled from the freshest child when stale (`isOld: true` or older by ≥60 s). The posting filter drops unaliased grouped children — the parent is the canonical entity; sub-items opt in by being aliased.
