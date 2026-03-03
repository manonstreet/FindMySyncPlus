# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FindMySyncPlus** is a macOS menu bar app (macOS 15+ only) that decrypts Apple Find My cache files and publishes device, item, and friend locations to Home Assistant via `device_tracker.see`. It is a pure Swift/SwiftUI/AppKit project built entirely in Xcode — no package manager, no scripts.

## Build & Run

Open and build in Xcode:
```
open FindMySyncPlus.xcodeproj
```

There is no CLI build, test runner, or lint script. All development happens through Xcode. For signing, enable "Automatically manage signing" and set a personal Team under Signing & Capabilities.

## Architecture

### App Lifecycle (`FindMySyncPlusApp.swift`)
The app starts as an `.accessory` (menu bar–only) process and switches to `.regular` when a window opens. `PolicyController` manages `NSApplication.activationPolicy`. `AppDelegate` + `WindowManager` handle window lifecycle. `WindowCoordinator` is a singleton that other code uses to open auxiliary windows.

Three `@ObservableObject` singletons are shared via the environment:
- **`AppModel`** — run engine, scheduler, sync logic
- **`SettingsStore`** — all user configuration (`@AppStorage` + Keychain)
- **`LogStore`** — in-memory log buffer (capped at 5000 entries)

### Data Flow
```
FMIP cache files (ChaChaPoly-encrypted)
  ~/Library/Caches/com.apple.findmy.fmipcore/Devices.data
  ~/Library/Caches/com.apple.findmy.fmipcore/Items.data
        ↓  Decryptor.swift (ChaChaPoly via CryptoKit; fmipKey from Keychain)

Friend locations (AES-256 encrypted SQLite)
  ~/Library/Group Containers/group.com.apple.findmy.findmylocateagent/
    Library/Application Support/LocalStorage.db
        ↓  FriendDecryptor.swift (page-level AES-CBC keystream XOR; localStorageKey from Keychain)

FMF contact names (ChaChaPoly-encrypted)
  ~/Library/Caches/com.apple.findmy.fmfcore/FriendCacheData.data
        ↓  Decryptor.readFMFContactNames (fmfKey from Keychain; maps DSID → displayName)

        ↓
  AppModel  (matches UUIDs to DeviceAlias records, dedup friends via DSID)
        ↓
  HTTP POST → Home Assistant device_tracker.see endpoint
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
| `Models/AppModel.swift` | Scheduler, run execution, HA posting, UUID learning |
| `Models/SettingsStore.swift` | All persisted config; Keychain wrappers for auth token and 3 decryption keys |
| `Models/DeviceAlias.swift` | Alias↔UUID mapping model |
| `Models/LogStore.swift` | Logging with levels; consumed by StatusView |
| `Decryptor.swift` | `actor` — FMIP cache decryption (ChaChaPoly), FMF contact name lookup, HA posting |
| `FriendDecryptor.swift` | `actor` — LocalStorage.db decryption (AES-256-CBC page-level), SQLite friend query |
| `Views/DeviceManagerView.swift` | Assign aliases to discovered UUIDs; source badges (Device/Item/Friend) |
| `Views/AccessSettingsView.swift` | HA endpoint, auth token, segmented key management UI with bulk import |
| `Helpers/Keychain.swift` | Generic SecItem wrapper; keys: `fmipSymmetricKey`, `fmfKey`, `localStorageKey` |

### Device Identity
`dev_id` is `findmy_<alias>` (lowercased slug). UUIDs for AirTags and iPhone/Apple Watch rotate; `auto-learn UUIDs` in `AppModel` updates `DeviceAlias` when a known device is seen under a new UUID. Dry-run mode reads and decrypts but never POSTs to HA.

## Testing

13 unit tests in `FindMySyncPlusTests/DecryptorTests.swift` covering `parseDeviceArray`, `extractSymmetricKey`, and async `decryptPayload`/`readEncryptedPayload`. Tests use synthetic ChaChaPoly data — no real Find My files required. Run via Xcode (Cmd+U) or xcodebuild test.

## Conventions
- `AppModel`, `SettingsStore`, `LogStore` are `@MainActor final class` using `@Published` + Combine for reactivity.
- `Decryptor` is an `actor` — disk I/O and ChaChaPoly decryption run on the actor's cooperative thread pool executor, not the main thread. `fmipKey` and `fmfKey` isolation is compiler-enforced. `parseDeviceArray` and `extractSymmetricKey` are `nonisolated` (pure functions). `post` and `testEndpointAuthentication` are `@MainActor` (access SettingsStore).
- `FriendDecryptor` is an `actor` — AES-256-CBC page-level decryption of LocalStorage.db with WAL support. `decryptPage`, `parseWAL`, `buildDecryptedDB` are `nonisolated` (pure crypto). Friends are deduplicated against family devices using DSID (Apple's universal person ID).
- Keychain reads/writes are synchronous wrappers around `Security.framework`.
- Transient network errors do not mutate `endpointAuthStatus`; only explicit 401/403 marks it invalid.
- `LSUIElement = YES` in Info.plist hides the Dock icon by default; `PolicyController` shows it when a window is open.
- `SettingsStore.batchUpdateLastSeenNames` batches all alias name updates into a single UserDefaults write per run cycle.
