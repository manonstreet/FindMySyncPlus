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

**Identity model**
- `dev_id = findmy_<alias>`
- `host_name = findmy_<alias>` (must match `dev_id` so HA entity_id aligns with the alias)
- `mac = <alias-derived MAC>`
  The MAC address is a stable value derived from the device's alias, ensuring consistent identification without relying on UUIDs.
- We do **not** send `location_name` to preserve Home Assistant zone detection.
- Battery percentage is included when available.

**Workflow**
- **Unassigned** lists entities (devices and items) we’ve seen with location but no alias.
- Click **Assign** to create an alias (prefilled from the entity name). You can add more UUIDs later if Apple rotates them.
- - When a device with the same name is discovered again, an **Update** behavior occurs: the existing device record is refreshed with the new information, maintaining continuity in device tracking.
- In **Aliases**, toggle **Tracked** to include an alias in posts.

**UUID rotation**
- If Apple rotates a device or item UUID, add the new UUID to the same alias. The HA entity remains `findmy_<alias>`.
- The app keeps the last N UUIDs per alias (configurable in Settings) and evicts older ones automatically to maintain a clean and efficient identity database.

**Dry Run**
- Shows what would be sent (including `dev_id`, `host_name`, and `mac`), but does not post to HA.

**Notes**
- Renaming an alias **changes the entity id** in HA (because `dev_id`/`host_name` change).
- Only tracked aliases are posted.
- After aliases are posted, if desired, copy the device names from the Aliases pane using the copy button, and replace the name attribute for each device in Home Assistant's `known_devices.yaml`.
"""
