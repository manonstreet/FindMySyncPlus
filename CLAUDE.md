# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FindMySyncPlus** is a macOS menu bar app (macOS 14.4+) that decrypts Apple Find My cache files and publishes device, item, and friend locations to Home Assistant. Supports **REST** (`device_tracker/see`) and **MQTT** (with HA auto-discovery and rich attributes) transports. It is a Swift/SwiftUI/AppKit project built in Xcode, with two Swift package dependencies (CocoaMQTT, Ink) pinned in `Package.resolved`.

## Worktrees: land the branch before you finish

Worktrees are fine, and useful for parallel work on separate features. **The rule is that a
session does not end with its work stranded in one.**

Before finishing, land it:

```
# from inside the worktree
ExitWorktree(action: "keep")          # returns the session to this checkout
git merge --ff-only <feature-branch>
git push <remote> <release-branch>      # the repo's default branch, one per minor
```

**Why this is a rule rather than a nicety.** A worktree-isolated session cannot run git
against this checkout by any route — `-C` and `--git-dir` are blocked, `git branch -f` is
refused because the branch is checked out here, and `update-ref` moves the pointer while
leaving this checkout's files behind it, which is worse than stale. So a session that
finishes inside a worktree leaves the release branch behind and **cannot fix it from where
it is standing.**

That drift then survives releases and gets built from. It happened across two, and a full
test pass once ran against a two-day-old binary before anyone noticed.

**`ExitWorktree` works even when the session never called `EnterWorktree`** — the tool's own
description says otherwise. A previous session recorded "worktree isolation blocked the
merge" and handed the problem on; it was never blocked.

## Build & Run

Open and build in Xcode:
```
open FindMySyncPlus.xcodeproj
```

From the command line, `xcodebuild build` and `xcodebuild test` work with `-project FindMySyncPlus.xcodeproj -scheme FindMySyncPlus -destination 'platform=macOS'`. `scripts/build.sh [debug|harness|release|test]` wraps them: a Debug run, a Release build installed to `/Applications` for the harness, the release archive and DMG, or the test suite. It builds whichever checkout you are standing in, stamps that checkout's `HEAD` into the About window, and keeps its output under one `.build/` above the main checkout so the app's path — which macOS keys Local Network grants by — never changes. For signing, create `Configs/Local.xcconfig` (gitignored) containing `DEVELOPMENT_TEAM = <your team id>`; `Configs/Signing.xcconfig` includes it if present. That is all `xcodebuild` needs; in Xcode, automatic signing then finds the team on its own.

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
| `SyncEngine.swift` | Orchestrates one sync run via decomposed pipeline: `ensureKeys` → `readCaches` → `readFriends` → `enrichFriendNames` → `buildPlanAndLog` → `postAndReport`. Routes posting through `TransportClient` protocol. The two big phases live in their own extension files below |
| `SyncEngineParsing.swift` | `readAndParseCaches` as named steps: read and decrypt each cache, resolve group parents from both files, parse to `DevicePoint`, give groups their positions and separation state, publish the located entries to the UI |
| `SyncEnginePlanning.swift` | `buildPlanAndLog` as named steps: a device pass and a friend pass into one `PlanAccumulator`, with auto-learn and group-membership persistence factored out; then the unaliased-child filter, dedupe, and the run's metrics |
| `SyncEngineGrouping.swift` | Recognizing a group from either source, backfilling a parent's position from its pieces, separation, and the duplicate-id tie-break |
| `TransportClient.swift` | Protocol defining `post()`, `ensureConnected()`, `testConnection()` + shared `PostSummary` type |
| `HAClient.swift` | `RESTClient` — `@MainActor final class` conforming to `TransportClient`; HTTP posting + auth testing |
| `MQTTClient.swift` | `MQTTClient` — `@MainActor final class` conforming to `TransportClient`; MQTT with HA auto-discovery, rich attributes, auto-reconnect |
| `CacheDecryptor.swift` | `actor` — FMIP cache decryption (ChaChaPoly), FMF contact name lookup |
| `LocalStorageDecryptor.swift` | `actor` — LocalStorage.db decryption (AES-256-CBC page-level), SQLite friend query |
| `Models/SettingsStore.swift` | All persisted config; Keychain wrappers for auth token and 3 decryption keys |
| `Models/DevicePoint.swift` | Device location struct with `with()` copy method for safe field updates; carries `parentID` for grouped accessories (e.g. AirPods Case/Buds) |
| `Models/RichLocationAttributes.swift` | Rich location data (altitude, speed, course, motion state, location label) with Apple label decoder |
| `Models/AliasPartition.swift` | Splits the Aliases list into top-level rows, nested children and headers for groups that are not themselves aliased. Pure, so the cases are testable away from the view |
| `Helpers/FriendsAvailability.swift` | Whether this macOS provides friend locations. Injectable version seam — the macOS 14 branch cannot be exercised on any available hardware, so `spoofOSVersion` substitutes a version the way `demoRoot` substitutes a read root |
| `SyncEngineDiagnostics.swift` | Why each record did or did not produce a position: one `.info` summary per source per run, `.debug` detail per device |
| `Models/DeviceAlias.swift` | Alias↔UUID mapping model |
| `Models/LogStore.swift` | Logging with levels; consumed by StatusView |
| `Views/DeviceManagerView.swift` | Assign aliases to discovered UUIDs; source badges (Device/Item/Friend) |
| `Views/AccessSettingsView.swift` | Transport picker, MQTT/REST config, connection test, segmented key management UI with bulk import |
| `Helpers/Keychain.swift` | Generic SecItem wrapper; keys: `fmipSymmetricKey`, `fmfKey`, `localStorageKey` |

### Device Identity
`dev_id` is `findmy_<alias>` (lowercased slug). UUIDs for AirTags and iPhone/Apple Watch rotate; `auto-learn UUIDs` in `SyncEngine` updates `DeviceAlias` when a known device is seen under a new UUID. Dry-run mode reads and decrypts but never posts to HA.

## Testing

Twenty-seven test files. All use synthetic data — no real Find My files, no keys, no keychain reads. Trust
`** TEST SUCCEEDED **` rather than counting `passed on` lines — xcodebuild interleaves
timestamps into those, so a grep count drifts between identical runs.

| Test file | Covers |
|---|---|
| `BatteryParsingTests` | Apple reuses `batteryStatus` for two different things — a charging-state String in `Devices.data`, an Int ordinal in `Items.data`. Guards the split and the vendor scoping |
| `CacheDecryptorTests` | ChaChaPoly round-trips, parentID plumbing for grouped items |
| `FMIPFreshnessTests` | `location_timestamp` / `is_old` reaching Items. Rich attributes are built only on the friends path, so an AirTag previously carried no timestamp at all (#17) |
| `HAEntityIDTests` | `slugifyAlias` permits hyphens, HA's object part does not. Verified against HA source: `default_entity_id` is `cv.string` and HA slugifies anyway |
| `LocalStorageDecryptorTests` | AES-CBC page decryption, Apple location label decoding |
| `LocalStorageWALTests` | Synthetic SQLite WAL construction, frame parsing, salt validation, page merging |
| `ModelTests` | `DevicePoint.with()` copy semantics, motion-state mapping, parentID preservation |
| `MQTTDiscoveryTests` | HA removed `object_id` in Core 2026.4 and ignores it silently; asserts `default_entity_id` is published instead (#22) |
| `MQTTPublishSequenceTests` | Publish ordering via a recording `MQTTPublishing` — the clear-wait-republish sequence in re-registration *is* the behavior, and nothing else can check it |
| `SyncEngineGroupingTests` | Unaliased grouped-child filter, parent location backfill from freshest child |
| `AliasNestingTests` | The Aliases-list partition: persisted `parentAlias` join, orphans staying visible, headers for unaliased groups, one-level flattening and cycles. Cases taken from three real systems |
| `FriendsAvailabilityTests` | The macOS 15 gate and its spoof override. `resolve` is pure so the 14.x branch is testable without a test writing to the app's real `UserDefaults` |
| `LocationDiagnosticsTests` | The two no-location buckets and the summary wording. Asserts absences too — "Share My Location" and "powered off" must not come back |
| `TextSanitizationTests` | slugify, normalizeID |
| `AliasHeaderPersistenceTests` | A header for an unaliased group is drawn from persisted `parentAlias`, not only from the live grouping — the Aliases list is config and must survive devices being offline |
| `DuplicateIdentityTests` | Two records for one accessory landing on the same id (#27); the tie-break prefers this account's copy, which Apple marks `prsId == "owner"` |
| `GroupPositionAttributesTests` | `position_source` and `separation_status` — which piece a group's coordinate came from, and whether that piece stands for the group |
| `ItemGroupsSourceTests` | `ItemGroups.data` as a second group source, carrying the same identity as an embedded `itemGroup` |
| `RecordIdentityTests` | One id-resolution chain for building a `DevicePoint` and looking it up again — the `baUUID`-vs-`identifier` precedence disagreement behind #24 |
| `RicherAttributesTests` | The attributes chosen after measuring a real `Items.data`; keeps `streetAddress` and `floorLevel` struck |
| `SyncStatusAndAvailabilityTests` | The 1.5b rules as pure functions — stable client id, availability, the status entity, skipping repeated locations and the movement threshold. The largest file, 45 tests |
| `ViewRenderTests` | Offscreen renders of the Device Manager row views. Baseline comparison is opt-in via `FMS_BASELINE_DIR`; unset, it still asserts every variant renders and renders deterministically |
| `AppleRecordFixtureTests` | Proves `AppleRecordFixture`, the measured record builder the other files draw on: the eleven-key `location`, the twenty-one-key item, `$null` placeholders, and `timeStamp` as an `NSNumber` that bridges to `Double` where a literal `Int` would not |
| `RESTPayloadTests` | The `device_tracker/see` body — the six fields, `dev_id` and `host_name` equal, `mac` from the alias alone, battery as a whole percentage and absent when unreported. The REST path had no test while being every pre-MQTT user's migration path |
| `MQTTRefreshTriggerTests` | The inbound control path through the recording publisher: a live press fires, a retained one is dropped, and switching the setting subscribes or unsubscribes now rather than at the next connection |
| `StatusEntityTests` | `publishStatusEntity` as pure pieces — when it publishes, how the report sums the run, and the state-then-attributes sequence on the wire, both retained |
| `LicenseReflowTests` | The Licenses sheet's reflow of the bundle's license files: wrapped paragraphs join, blank lines and centered headings and short lines stay, and the GPL's notice-template placeholders are not run together |

Run via Xcode (Cmd+U) or xcodebuild test. A green suite is not sufficient for MQTT
changes — verify those against the demo fixtures, which caught two defects the
suite missed.

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
