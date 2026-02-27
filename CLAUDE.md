# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FindMySyncPlus** is a macOS menu bar app (macOS 15+ only) that decrypts Apple Find My cache files and publishes device locations to Home Assistant via `device_tracker.see`. It is a pure Swift/SwiftUI/AppKit project built entirely in Xcode — no package manager, no scripts.

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
Find My cache files (encrypted)
  ~/Library/Caches/com.apple.findmy.fmipcore/Devices.data
  ~/Library/Caches/com.apple.findmy.fmipcore/Items.data
        ↓
  Decryptor.swift  (AES decryption via CryptoKit; keys stored in Keychain)
        ↓
  AppModel  (matches raw UUIDs to DeviceAlias records in SettingsStore)
        ↓
  HTTP POST → Home Assistant device_tracker.see endpoint
```

Requires Full Disk Access to read the Find My cache. `FindMyRefresher.swift` can launch the Find My app to force a cache refresh.

### Key Files
| File | Role |
|------|------|
| `Models/AppModel.swift` | Scheduler, run execution, HA posting, UUID learning |
| `Models/SettingsStore.swift` | All persisted config; Keychain wrappers for auth token and decryption key |
| `Models/DeviceAlias.swift` | Alias↔UUID mapping model |
| `Models/LogStore.swift` | Logging with levels; consumed by StatusView |
| `Decryptor.swift` | Parses and decrypts Find My binary plist cache files |
| `Views/DeviceManagerView.swift` | Assign aliases to discovered UUIDs |
| `Views/AccessSettingsView.swift` | HA endpoint, auth token, key import |
| `Helpers/Keychain.swift` | Generic SecItem wrapper for secure storage |

### Device Identity
`dev_id` is `findmy_<alias>` (lowercased slug). UUIDs for AirTags and iPhone/Apple Watch rotate; `auto-learn UUIDs` in `AppModel` updates `DeviceAlias` when a known device is seen under a new UUID. Dry-run mode reads and decrypts but never POSTs to HA.

## Conventions
- All model classes are `@MainActor final class` using `@Published` + Combine for reactivity.
- Keychain reads/writes are synchronous wrappers around `Security.framework`.
- Transient network errors do not mutate `endpointAuthStatus`; only explicit 401/403 marks it invalid.
- `LSUIElement = YES` in Info.plist hides the Dock icon by default; `PolicyController` shows it when a window is open.
