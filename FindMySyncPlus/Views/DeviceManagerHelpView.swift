import SwiftUI

struct DeviceManagerHelpView: View {
    @State private var markdown: String = "# Device Management\n\nLoading…"

    var body: some View {
        MarkdownView(markdown: markdown)
            .frame(minWidth: 640, minHeight: 480)
            .onAppear(perform: load)
    }

    private func load() {
        if let s = loadMarkdownResource(named: "DEVICE-MANAGEMENT")
            ?? loadMarkdownResource(named: "DeviceManagement")
            ?? loadMarkdownResource(named: "device-management") {
            markdown = s
        } else {
            // Fallback content so the sheet is never blank
            markdown = defaultHelpMarkdown
        }
    }

    private func loadMarkdownResource(named base: String) -> String? {
        guard let url = Bundle.main.url(forResource: base, withExtension: "md"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return s
    }
}

// Keep this close by so you always see something even if the file is missing.

private let defaultHelpMarkdown = """
# Device Management

The Device Manager maps Find My entities to stable Home Assistant identities. It handles three source types — **Devices** (iPhones, Macs), **Items** (AirTags), and **Friends** (shared locations) — each shown with a color-coded badge.

## Unassigned

Lists discovered entities that don’t have an alias yet. Use the filter menu to show All, Devices, Items, or Friends.

- **Assign** — creates a new alias (prefilled from the entity name).
- **Update** — appears when a known device reappears under a new UUID. Adds the UUID to the existing alias automatically.

## Aliases

Shows all created aliases. Use the filter menu to narrow by source type.

- **Tracked toggle** — only tracked aliases are posted to Home Assistant.
- **Rename** (pencil icon) — changes the alias and HA entity ID.
- **Delete** (trash icon) — removes the alias from the app (does not affect HA).
- **Copy name** (clipboard icon) — copies the device’s original name for `known_devices.yaml`.

## How Identity Works

Each alias maps to a single HA entity: `dev_id` and `host_name` are both `findmy_<alias>`, and `mac` is derived from the alias for stability. Battery is included when available. `location_name` is omitted to preserve HA zone detection.

## UUID Rotation

Apple periodically rotates UUIDs. The device reappears in Unassigned with an **Update** button (matched by name). The app keeps the last N UUIDs per alias (configurable in General Settings) and evicts older ones. **Auto-learn UUIDs** can handle this automatically.

## Dry Run

Shows what would be posted without actually sending to HA.
"""
