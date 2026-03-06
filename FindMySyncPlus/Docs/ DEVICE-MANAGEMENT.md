# Device Management

The Device Manager maps Find My entities to stable Home Assistant identities. It handles three source types — **Devices** (iPhones, Macs), **Items** (AirTags), and **Friends** (shared locations) — each shown with a color-coded badge.


## Unassigned

Lists discovered entities that don't have an alias yet. Use the filter menu to show All, Devices, Items, or Friends.

- **Assign** — creates a new alias (prefilled from the entity name). The alias becomes the stable HA identity.
- **Update** — appears instead of Assign when a known device reappears under a new UUID. Clicking it adds the UUID to the existing alias automatically.


## Aliases

Shows all created aliases. Use the filter menu to narrow by source type.

- **Tracked toggle** — only tracked aliases are posted to Home Assistant. Flip it off to keep an alias without posting.
- **Rename** (pencil icon) — changes the alias. This also changes the HA entity ID, so rename with care.
- **Delete** (trash icon) — removes the alias from the app. Does not remove anything from HA.
- **Copy name** (clipboard icon) — copies the device's original name for use in `known_devices.yaml`.
- **Remove UUID** — click the X on any UUID to unlink it. If it's the last UUID on a tracked alias, you'll get a confirmation warning.


## How Identity Works

Each alias maps to a single HA entity using three derived fields:

| Field | Value | Purpose |
|-------|-------|---------|
| `dev_id` | `findmy_<alias>` | HA entity identifier |
| `host_name` | `findmy_<alias>` | Matches `dev_id` so entity IDs align |
| `mac` | Derived from alias | Stable ID that doesn't depend on rotating UUIDs |

Battery percentage is included when available. `location_name` is intentionally omitted to preserve HA zone detection.


## UUID Rotation

Apple periodically rotates device and item UUIDs. When this happens:

1. The device appears in **Unassigned** with an **Update** button (matched by name).
2. Click **Update** to add the new UUID to the existing alias.
3. The HA entity stays the same — no disruption.

The app keeps the last N UUIDs per alias (configurable in General Settings) and automatically evicts older ones. If **Auto-learn UUIDs** is enabled, the app detects name matches and adds new UUIDs without manual intervention.


## Dry Run

Shows exactly what would be posted (including `dev_id`, `host_name`, `mac`, and coordinates) without actually sending to HA. Useful for verifying aliases before going live.
