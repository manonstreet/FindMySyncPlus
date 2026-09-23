# Changelog

Release notes for each FindMySyncPlus release, newest first. Each entry is the text published with that release, minus its install steps. The DMGs are on the [Releases page](https://github.com/manonstreet/FindMySyncPlus/releases).

## [v2.0b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v2.0b) — 2026-09-23

Rebuilds the interface as one window with six panes, adds automatic updates, and corrects the install steps for macOS 15.

### Added

**Automatic updates.** FindMySync+ checks for a new release once a day and offers to install it. Each update is signed, and the signature is checked before it installs.

### Changed

**The interface is rebuilt.** Six panes in a single window with a sidebar — Home, Status, Tracking, Access, General and About — in place of the settings window and both Device Manager windows. Each pane has a colored icon in the sidebar, and settings are grouped into cards.

**Device Manager is now Tracking**, a pane in that window. The same aliases and the same two lists, with grouped accessories shown under their parent.

**Tracking's help opens beside the list it describes**, and covers grouped accessories such as AirPods and what reaches Home Assistant.

**Each acknowledgment in About links to its own license.** The sheet opens at that license, and the text reflows to the width of the sheet.

**The menu bar icon is a template symbol**, so macOS tints it with the rest of the bar in light, dark and highlighted states.

**Install steps for macOS 15.** Apple removed the right-click-and-Open shortcut for software that is not notarized. The steps on the Releases page use Privacy & Security instead.

### Fixed

**Menus took the whole width of their row on macOS 15.** The Log Level menu in Status and both filters in Tracking size to their content.

**The Tracked switch drew its knob over the end of its track**, covering the colored cap.

## [v1.5b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.5b) — 2026-09-08

Publishes an entity update only when a location actually changes, reports what each sync did through a new Sync status entity, and lets Home Assistant ask for a refresh.

### Added

**Skip repeated locations.** Publishes an entity update only when Find My reports a different location, rather than on every sync. Off by default, MQTT only. Requested by @enduring78.

**Minimum movement.** A distance in meters below which a location counts as unchanged. Apple recomputes a position on every refresh, so a stationary tracker lands a fraction of a meter away each time and reads as movement; half a meter absorbs that. At 0 only exact coordinate matches are skipped.

**Sync status entity.** `sensor.findmysyncplus_status` holds the time of the last successful sync, and its attributes describe the run behind it — what was found, what was published, what was skipped, and the state of the app's keys and access. With Skip repeated locations on, a tracker that has not moved stops updating, so this is where you look to confirm the app is still working. It keeps its values while the app is disconnected.

**Connected sensor.** A `connectivity` binary sensor following the app's MQTT connection. It has a history in the recorder, so disconnects can be charted and used as automation triggers.

**Subscribe to sync requests.** Discovers a "Refresh and sync" button in Home Assistant. Pressing it launches Find My and runs one sync, even with "Launch Find My before each run" switched off. Presses inside 60 seconds of the last one are dropped. Off by default, MQTT only. Requested by @eigenphase.

**Battery sensors report unavailable while the app is disconnected.** A stale percentage keeps drawing a level line on the statistics graph as though it were still being measured.

**Better logging.** The run summary carries `find_my=` and `cache_age=`, so a pasted line says whether Find My was launched and how old the cache was. Skips are counted with their reason — `MQTT: 11 entities not republished (11 identical)`. Connecting and disconnecting are both announced. At Debug, a line names which file each group came from.

**Test hooks in the source.** The app can render its own screens and write out a run's log, so both can be checked against recorded results. Dormant unless switched on.

### Changed

**`last_update` marks the last location change, not the last sync.** It carried the time the app published, so it advanced on every run whether the position had moved or not. It now carries the time Find My recorded the position, and with Skip repeated locations on an entity's last-updated in Home Assistant follows real movement.

**The scheduler runs during sleep again.** It was suspended in 1.4.7b because locations go stale while a Mac sleeps and the entities kept republishing as though they were fresh. Skip repeated locations addresses that directly: only a position that moved is republished, asleep or awake. A run that overlaps a sleep can take a long time to finish, so it now reports `slept_during_run` and a run of several minutes explains itself. Reported by @minimicro34.

### Fixed

**The broker collected a dead client entry on every launch.** The app introduced itself with a fresh random client id each time; it now keeps one per install.

## [v1.4.7b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4.7b) — 2026-09-06

Reports which piece a group's location belongs to, adds an address for a piece left behind, and stops a shared accessory flapping between two locations.

### Added

**Group location provenance.** A group has no location of its own; it publishes a piece's. `position_source` names which piece, or `self` where Apple gave the group a location directly.

**When the pieces are apart.** `separation_status` is `together`, `separated`, or `unknown` when a piece last reported too long ago to compare. Separated covers a bud out of its case and the two buds apart from each other.

**Address on separated pieces.** `pieces` carries each piece's address and how old that location is, published only while `separation_status` is `separated`.

At debug level the Status window also logs Apple's own grouping of the pieces. It can lag behind the locations, both when the pieces separate and when they come back together.

### Changed

**A separated group takes the case's location.** It previously took whichever piece reported last, which could swing the entity between two places from one run to the next.

**The scheduler suspends on device sleep.** It starts again on wake. Locations go stale while the Mac sleeps: Power Nap refreshes some of them, inconsistently. Thanks to @minimicro34.

### Fixed

**An accessory paired to a family member's devices no longer flaps between two locations.** Apple stores a separate copy for each account and both published to the same entity in a single run, so Home Assistant showed one and the other replaced it a moment later. The app now publishes the copy belonging to this Mac's account, and names both in the log. Thanks to @eigenphase.

**A group could keep a stale location.** On some Macs it could not match its own pieces, so it never picked up their current ones. Thanks to @DriesA.

**Home Assistant no longer logs a warning when battery data is missing.** The battery sensor's template produced one on every update for a device that reports no battery level. The entity keeps its last known percentage.

**A chosen log level survives a restart.** Warn and Error are remembered. Debug returns to Info on launch, because it fills the log buffer in a few hours.

## [v1.4.6b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4.6b) — 2026-08-31

Nests grouped accessories in Device Manager, adds a street address and a low-battery flag to your entities, and reports why a device has no location.

### Added

**A street address.** Home Assistant has no reverse geocoding built in, so getting a street name onto a tracker normally means installing a separate integration and wiring it up. `address` now arrives on every entity Apple provides one for — house number, street and city, formatted by Apple.

Items also carry `role` and `role_emoji`, the category and emoji chosen when the item was set up, and `is_inaccurate`, Apple's own assessment of the position it reported.

**A low-battery flag for Apple items.** `battery_low` on AirTags and AirPods. Its boolean value matches Find My's low-battery banner, so an automation fires on the same threshold Apple shows you.

Third-party trackers use vendor-defined codes that mean different things on different hardware, rendering the flag unreliable and suppressed for non-Apple items. They continue to report `battery_status_raw`, which you can map yourself.

**Battery statistics.** The battery sensor declares `state_class: measurement`, so Home Assistant records long-term statistics for it and battery level appears in the statistics graph. Statistics start from the upgrade; existing history is unaffected.

**The Status window reports why a device has no location.** One summary line for each source on every run: how many devices have no position at all, and how many have only a Find My network detection. At debug level there is a line per device with its position type, accuracy and age. Most "why is this one not updating" questions are now answerable from the window.

**Copy the whole Status log.** One button puts the entire log on the clipboard, so a full run can go into an issue without needing to take screenshots.

**A location from the Find My network.** When a device reports no location of its own, the app publishes where nearby Apple devices last detected it, with `position_type` naming the source so an automation can treat it differently from a current position.

Detections Apple flags as old are skipped. They are often days stale and a long way off, and Home Assistant computes zone state from coordinates whatever the attributes say. Thanks to @DriesA, who found the signal that separates a usable detection from a stale one.

**Five more location attributes.** `position_type`, `altitude`, `vertical_accuracy`, `speed` and `course`, on devices and items, whenever Apple reports them. Altitude appears only when Apple's own accuracy figure says it is valid.

### Changed

**Friend locations require macOS 15 or later.** On macOS 14, Find My itself reports no location for the people sharing with you, and I have been unable to locate where the cache is stored on disk for this OS (if at all). The Friends toggle is disabled and the two keys it needs are greyed out and marked *Needs macOS 15*.

The practical effect is that macOS 14 needs **one key instead of three** — the other two decrypt friend names and friend locations, and neither is usable there. Devices and Items are unaffected. Thanks to @DriesA and the testers on #19, whose side-by-side comparison of the same account on both versions settled what macOS 14 actually does.

**Grouped accessories nest in the Aliases list.** A fully aliased pair used to show as three unrelated rows. They now nest under the group, and an unaliased group appears as a header so its children still read as a set. Groups are labelled `Group` rather than `Device`.

Pairs that never grouped on some Macs now do. Apple stores the grouping in one of two places depending on the machine, and the app previously read only one of them.

### Fixed

**Groups stay in Device Manager.** A group with no position of its own was dropped along with its children, so an AirPods pair could vanish from both lists entirely and its members render flat. The group now takes the position of its freshest member.

**The Find My Friends key indicator reports whether the key works.** It could sit on "Loaded" indefinitely for cases where there are no shared friends and/or locations, because with nothing to look up the key was never consulted. It is now checked whenever Friends is switched on, so it reads valid or invalid.

## [v1.4.5b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4.5b) — 2026-08-23

Adds macOS Sonoma support, fixes entity IDs not following your alias on current Home Assistant, and adds a battery sensor.

### Added

**macOS 14.4 (Sonoma) is now supported.** The minimum was macOS 15. All three encryption keys extract and verify on Sonoma, including the one Friends needs. Thanks to the testers on #19, and to @DriesA, whose extractor fix made key extraction work there.

> **Correction, 2026-08-23:** this section originally said to expect full feature parity on Sonoma. That was based on key extraction verifying, which turns out to be a separate question from whether the caches parse. On 14.4, Items work; Devices report no location and Friends fails on a missing database table. Both are being investigated in #19. Support on 14.4 should be read as Items only until that is resolved.

**A battery sensor.** Devices that report a real battery level — iPhone, Apple Watch, Mac — now get a sensor with `device_class: battery`, so battery works with the battery card and low-battery blueprints instead of needing a template sensor built on an attribute.

AirTags and third-party trackers do **not** get a sensor. They report a manufacturer-specific code rather than a percentage, and the same number has different meanings on different hardware, making it not practical to normalize across vendors. They continue to report `battery_status_raw`, which you can map yourself. A low-battery flag limited to Apple items, where the code is understood, is planned but not in this release.

Devices with no battery reading do not publish a sensor, rather than one stuck at `unknown`.

**Two location attributes.** `is_old` is Apple's own flag for whether a location is stale — useful if you want an automation to ignore old positions. And `location_timestamp`, the time Find My recorded the location, now appears on Devices and Items. It previously only appeared on entries that came from Friends data, which meant AirTags carried no timestamp.

**MQTT connection status in the sidebar**, with the broker in its tooltip. Clicking it opens Access settings.

### Fixed

**Entity IDs did not follow your alias.** Home Assistant removed the `object_id` discovery option in Core 2026.4, and had been silently ignoring it since — no error, nothing in the logs. Without it, Home Assistant names entities after the device instead, so an alias of `kitchen-keys` arrived as `device_tracker.findmysync_keys`. FindMySyncPlus now sends the replacement, `default_entity_id`.

This only affected entities created for the first time on Home Assistant 2026.4 or later — a new install, or a new alias added to an existing one. Home Assistant keeps the entity ID it assigned originally, so anything created before then was not affected.

**Device Manager showed the wrong entity ID.** Its "Entity ID" row showed the MQTT topic key rather than the entity ID Home Assistant creates from it. It now shows the real one, with a copy button.

**Renaming or deleting an alias left its old entity behind.** The old MQTT topics stayed on the broker permanently, so Home Assistant kept showing an entity you could not remove, and the device's last position stayed published under a name you
had deleted. Those are now cleared, whether or not the scheduler is running. Renaming also runs a sync, so the new entity appears straight away rather than at the next scheduled run.

### If your entity IDs are wrong

Only entities created on Home Assistant 2026.4 or later are affected, and updating does not rename them — Home Assistant keeps the ID it already assigned. Two ways to fix one:

- Rename it in Home Assistant under Settings → Entities. Home Assistant keeps that, and later discovery messages will not overwrite it.
- Or use **Re-create entity**, the new action on the alias row in Device Manager. This removes the entity so Home Assistant assigns the ID again. It clears any rename, icon or area you set there, and recorded history stays under the old entity ID. The confirmation names the entity and the ID it will become.

## [v1.4.4b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4.4b) — 2026-08-21

Patch release on the 1.4 beta line. One fix, for a bug that made Friends silently do nothing on some machines.

### Fixed

**Friends never appeared on some Macs, with no error.** macOS keeps the Find My friends database in one of two places, depending on when it was first created. It never moves after that, so two Macs running the same macOS version can differ. FindMySyncPlus only checked one of them, and when the file was not there it skipped Friends with a debug-level message — invisible at the normal log level. Reported in #21.

The app now checks both places, and verifies it can decrypt a database before using it. If neither works, it logs a warning listing the paths it checked.

### If Friends were not working for you

Update and run a sync. If Friends still do not appear, set the log level to Debug in the Status window and look for a line starting `Friends:` — it will name the paths that were checked, which is the information needed to diagnose it.

## [v1.4.3b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4.3b) — 2026-08-17

Patch release on the 1.4 beta line — battery fixes and MQTT reliability.

### Fixed

- **Devices with no battery reported 0%.** Anything without a battery — a desktop Mac, AirPods that aren't reporting — still carries a zero in Apple's cache, and it was published as a real reading. On a test machine 11 of 25 devices were sending 0% to Home Assistant, a permanent false alarm for anyone building a low-battery automation. Reported in #16.
- **AirTag and third-party tracker batteries were divided by 100.** Trackers don't report a percentage, they report a status code, and it was being treated as one — so a tracker reporting `2` reached Home Assistant as 2%. Reported in #16.
- **A brief network gap at startup caused a skipped sync.** If the network isn't usable for a moment when the app starts, the MQTT connection failed and wasn't retried for five seconds, so the first sync was abandoned. Related to #20.

### Changed

- **Battery is now published as four attributes** instead of one, because Apple stores it two different ways and reuses the same field name for both:

  | Attribute | What it is |
  |---|---|
  | `battery` | Percentage, 0–100 — only where a real level is reported |
  | `battery_level_raw` | The underlying 0–1 value |
  | `battery_status_raw` | A tracker's status code, untouched |
  | `charging_state` | Charging / NotCharging / Unknown |

- **Tracker status codes are not converted into percentages.** Values seen across users — 0, 1, 2, 4, 5, 100 from Apple, Sitecom and World Tag hardware — sit on scales that can't be reconciled, and guessing would feed wrong numbers into automations. The raw value is published so you can map your own.
- **Unmapped motion states** now appear as `unmapped(6)` rather than `unknown`, so a new Apple activity type is visible rather than silently indistinguishable from a real reading.
- **MQTT reconnect** now starts at 250 ms and backs off from there, instead of starting at 5 seconds.

### Upgrade note

If you have a template sensor or automation reading the `battery` attribute of an **AirTag or third-party tracker**, it will stop returning a value — that number was wrong (a status code shown as a percentage), and it's now published as `battery_status_raw` instead. Phones, watches and AirPods are unaffected.

## [v1.4.2b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4.2b) — 2026-08-06

Patch release on the 1.4 beta line — Friends reliability fixes, no new features.

### Fixed

- **Friends failed with "database disk image is malformed"** when `LocalStorage.db` is a single page and the live data still lives in the WAL. WAL frames referencing pages past end-of-file were silently dropped, leaving a stub database. Thanks to @danperks for the diagnosis and fix (#15).
- **Stale friend locations after a WAL checkpoint.** SQLite restarts the WAL with new salts but leaves the previous generation's frames in the file at higher offsets, so a last-writer-wins merge could let stale pages overwrite current ones. Frame salts are now validated against the WAL header and parsing stops at the first mismatch.
- **Uncommitted transactions are no longer replayed.** Only frames up to the last commit frame are applied, so a read that lands mid-write no longer reconstructs a torn database.
- **Crash and runaway-allocation guards.** A frame with page number 0 mapped to index -1; an unvalidated page number could drive the page array toward terabytes of allocation. Both are now bounded and rejected.

### Changed

- WAL validation reports what it discarded to the status log, so a discard that goes too far is diagnosable instead of surfacing as a misleading "LocalStorage key is incorrect".
- WAL parsing is roughly 2x faster — frame headers are scanned first so only the surviving pages are copied, instead of copying every frame.

### Internal

- Test target now auto-discovers new test files; previously a new test file compiled and was silently excluded from the target.
- Test suite grew from 70 to 92, covering WAL frame validation and the page merge — neither had any coverage before.

## [v1.4.1b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4.1b) — 2026-05-07

### Bug Fixes & Polish

- **HA device card** — MQTT auto-discovery now publishes a `device` block, so all FindMySync+ tracked entities group under a single **FindMySync+** device card in Home Assistant's *Devices & Services* view. Existing v1.4b users: restart Home Assistant after upgrading to relink existing entities to the new device card. Fixes #12.
- **Device Manager badge colors** — *Item* badges now render green as documented (previously matched *Device* blue); *Friend* stays purple. The *Assigned* badge for grouped parents moves from green to gray to avoid clashing with Items.
- **Disclosure UX** — the chevron on grouped parent rows (e.g. AirPods Pro) is now always visible inline with the source/Assigned badges, instead of revealing only on hover. More discoverable and less floaty.

## [v1.4b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.4b) — 2026-05-06

### What's New

- **Grouped accessories** — AirPods Pro pairs (and similar) now appear as a single Device Manager entry instead of three separate "Case" / "Left Bud" / "Right Bud" rows. Hover over a grouped row and click the chevron to expand and individually alias buds (useful for finding a lost one). Aliased grouped parents stay visible with an "Assigned" badge.
- **Smarter parent location** — when an AirPods pair's reported location is stale, FMS+ now backfills it from the freshest connected component, so the parent entity in Home Assistant always reflects the most current known location.
- **Cleaner posting model** — sub-items (buds, etc.) only publish to HA if you've explicitly aliased them. The parent group is the canonical "AirPods" entity by default — no more clutter of three entities per pair.
- **Generic** — works for any Apple/MFi accessory that uses Apple's group structure, not just AirPods.

## [v1.3.1b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.3.1b) — 2026-03-21

### Bug Fix

- **MQTT zone duration fix** — MQTT transport was publishing a `not_home` state on every sync cycle, causing Home Assistant to reset zone duration each run instead of showing continuous time in a zone. State is now derived entirely from GPS coordinates.

## [v1.3b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.3b) — 2026-03-19

### What's New

- **Transport protocol** — unified `TransportClient` interface for REST and MQTT, cleaner internal architecture
- **MQTT as default** — new installs default to MQTT transport; existing REST users are preserved
- **Auto-reconnect** — MQTT automatically reconnects after unexpected broker disconnects
- **UI polish** — consistent field alignment in Access Settings, infotip text wrapping fix, unified "Verify" button across transports, transport switch warning about stale entities
- **Help docs** — Device Manager help updated for MQTT, rich attributes, and family dedup
- **New tests** — 58 unit tests (was 53)
- **Updated screenshots**

## [v1.2b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.2b) — 2026-03-14

### What's New

- **MQTT transport** — publish locations via MQTT with full Home Assistant auto-discovery. Rich attributes (altitude, speed, course, motion state, location label) available on each entity's `json_attributes_topic`
- **Rich attribute merge** — family members tracked via FMIP now include altitude, speed, course, and motion state from LocalStorage
- **Location label decode** — Apple's encoded location labels (`_$!<home>!$_`) are decoded to readable names (Home, Work, etc.)
- **MQTT auto-reconnect** — automatically reconnects to broker after unexpected disconnects

## [v1.1b](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.1b) — 2026-03-08

### What's New in v1.1b (Beta)

- **Friend location tracking** — decrypts LocalStorage.db to publish friend locations to Home Assistant
- **FMF contact name lookup** — resolves friend display names from FriendCacheData.data
- **Consolidated key management UI** — segmented picker (All / Find My / FMF / LocalStorage) with bulk "Import All from Folder"
- **Refactored architecture** — separated CacheDecryptor, LocalStorageDecryptor, SyncEngine, and HAClient into focused single-responsibility types
- **Updated Device Management help** — now covers Devices, Items, and Friends with filter menus, source badges, and auto-learn UUIDs
- **52 unit tests** across CacheDecryptorTests, TextSanitizationTests, and LocalStorageDecryptorTests
- **SwiftLint** integrated with GitHub Actions CI

## [v1.0.2](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.0.2) — 2026-02-28

### What's changed

- **Performance**: `DateFormatter` instances moved to `static let` — no longer allocated on every menu bar render
- **Performance**: Alias name updates now batched into a single `UserDefaults` write per sync run instead of one write per device

## [v1.0.1](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.0.1) — 2026-02-28

### What's changed

- **Thread safety**: Decryptor converted to Swift actor — disk I/O and decryption now run off the main thread
- **Bug fix**: `readEncryptedPayload` correctly runs on the actor's background executor (was inadvertently blocking main thread)
- Unit test suite added (13 tests covering decryption, key extraction, device parsing)

## [v1.0.0](https://github.com/manonstreet/FindMySyncPlus/releases/tag/v1.0.0) — 2025-11-10 — Initial release

This version may have bugs. I have been running it for about a month without issue but your mileage may vary.
