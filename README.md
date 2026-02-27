# FindMySyncPlus

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
![Swift](https://img.shields.io/badge/Swift-native-orange)

> Publish Apple Find My locations to Home Assistant — privately, locally, no third-party services.

FindMySyncPlus reads your encrypted Find My cache files, decrypts them, and posts location updates
directly to your Home Assistant instance on a configurable schedule. No cloud relay. No tracking
service. Your Find My data goes straight to your home network and nowhere else.

It supports both Devices (iPhones, Apple Watch) and Items (AirTags), handles rotating UUIDs
automatically, and stores all sensitive credentials securely in the macOS Keychain.

Based on [FindMySync](https://github.com/MartinPham/FindMySync) and the decryption research by
[Pnut-GGG](https://github.com/Pnut-GGG/findmy-cache-decryptor).

---

## Why FindMySyncPlus?

|  | FindMySyncPlus | FindMySync (original) | iCloud3 |
|--|:-:|:-:|:-:|
| macOS 15+ (Sequoia) support | ✅ | ❌ | N/A |
| AirTag / Items support | ✅ | ✅ | ❌ |
| Auto-refresh Find My (no AppleScript) | ✅ | ❌ | N/A |
| Auto-learn rotating UUIDs | ✅ | ❌ | N/A |
| Apple ID credentials required | ❌ | ❌ | ✅ |
| HA Mobile App on tracked devices | Not required | Not required | Recommended |
| Connects to Apple iCloud API | ❌ Never | ❌ Never | ✅ |
| Runs inside Home Assistant | ❌ Requires a Mac | ❌ Requires a Mac | ✅ |
| Initial setup complexity | Moderate (key extraction) | Low | High |
| Ongoing configuration | Low | Low | High |
| Update frequency | Configurable (≥1 min) | External AppleScript | Near real-time |

---

## Features

- Tracks both **Devices** (iPhone, Apple Watch) and **Items** (AirTags)
- **Device Manager** — assign friendly aliases to devices; aliases become stable HA entity IDs even as UUIDs rotate
- **Auto-learn UUIDs** — automatically re-maps devices when Apple rotates their identifier
- Configurable scheduler with selectable refresh interval and manual **Run Now** and **Dry Run** modes
- **Four log levels** (Error / Warn / Info / Debug) with per-run statistics — posted updates, warnings, learned UUIDs
- Optionally auto-launches Find My to refresh cache before each sync — no AppleScript required
- All credentials (encryption key, HA token) stored in the macOS **Keychain**
- Menu bar agent — runs silently in the background with open-at-login support
- Full Disk Access gating with clear in-app guidance when permission is missing

---

## Screenshots

<p>
  <a href="screenshots/home_view.png"><img src="screenshots/home_view.png" width="230" alt="Home"></a>
  <a href="screenshots/status_view.png"><img src="screenshots/status_view.png" width="230" alt="Status"></a>
  <a href="screenshots/device_manager.png"><img src="screenshots/device_manager.png" width="230" alt="Device Manager"></a>
</p>
<p>
  <a href="screenshots/access_settings.png"><img src="screenshots/access_settings.png" width="230" alt="Access Settings"></a>
  <a href="screenshots/general_settings.png"><img src="screenshots/general_settings.png" width="230" alt="General Settings"></a>
  <a href="screenshots/about_view.png"><img src="screenshots/about_view.png" width="230" alt="About"></a>
</p>

---

## Requirements

- macOS 15 (Sequoia) or higher
- A running Home Assistant instance with the `device_tracker.see` API enabled
- FMIPDataManager encryption keys extracted from Keychain (see Phase 1 below)

---

## Getting Started

### Phase 1 — Prerequisites

Extract your FMIPDataManager encryption keys using
[FMIPDataManager-extractor](https://github.com/Pnut-GGG/FMIPDataManager-extractor).
This is a one-time step and a hard requirement — FindMySyncPlus cannot decrypt Find My data without it.
Technical support for the extraction tool is outside the scope of this project.

### Phase 2 — Install

Download the latest binary from [Releases](../../releases) and move it to your Applications folder,
or clone the repo and build in Xcode with automatic signing enabled.

### Phase 3 — Configure

Launch the app and open the **Access** pane (the Home screen will show "Not Set" errors — click one):

1. Enter your Home Assistant `device_tracker.see` endpoint URL
2. Enter your Authorization header (include the `Bearer` prefix)
3. Click **Test Auth** to verify the connection
4. Click **Import Key** and select the `FMIPDataManager` plist exported in Phase 1
   — do not select `FMFDataManager` (Find My Friends), which is also exported by the tool
5. Click **Open Preferences** and grant Full Disk Access
6. Quit and relaunch the app

If prompted by Keychain, click **Always Allow**.

> **Building from source?** In Xcode under Signing & Capabilities, enable Automatically manage signing
> and set your Team to your personal developer certificate — this eliminates Keychain prompts entirely.

Under the **General** pane, recommended settings:
- Enable **Open at Login**
- Disable **Open Main Window on Startup** (runs as a menu bar agent)
- Enable **Auto-start Scheduler**
- Enable **Auto-learn UUIDs**

### Phase 4 — First Run & Device Manager

1. Open the **Status** pane and set log level to **Debug**
2. Click **Run Now** (▶) in the toolbar and review the logs — all discovered devices and items appear here
3. Open **Device Manager** and click **Assign** for each device you want to track
4. Give each device an alias — the Home Assistant entity will be `findmy_<alias>`
5. Return to the **Home** pane and enable the **Scheduler**

**Optional:** In Home Assistant, edit `known_devices.yaml` to add friendly names:
```yaml
findmy_alias1:
  name: "Alice's AirTag"
  track: true
```

---

## A Note on AI Co-creation

This project was my first experience building software collaboratively with AI — using ChatGPT,
Gemini, and Claude as thinking partners throughout the process. It started as a learning exercise
and grew into a working tool I run daily. The code reflects that journey.

---

## Acknowledgements

- [FindMySync](https://github.com/MartinPham/FindMySync) by Martin Pham — the original project this is based on
- [findmy-cache-decryptor](https://github.com/Pnut-GGG/findmy-cache-decryptor) by Pnut-GGG — reverse-engineered the Find My encryption
- [FMIPDataManager-extractor](https://github.com/Pnut-GGG/FMIPDataManager-extractor) by Pnut-GGG — key extraction tool required for setup
- [Ink](https://github.com/JohnSundell/Ink) — MIT-licensed Markdown parser used in-app
