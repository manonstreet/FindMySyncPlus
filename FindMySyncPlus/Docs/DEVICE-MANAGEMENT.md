# Device Management

The Device Manager maps Find My entities to stable Home Assistant identities. It handles three source types — **Devices** (iPhones, Macs), **Items** (AirTags), and **Friends** (shared locations) — each shown with a color-coded badge.


## Unassigned

Lists discovered entities that don't have an alias yet. Use the filter menu to show All, Devices, Items, or Friends.

- **Assign** — creates a new alias (prefilled from the entity name). The alias becomes the stable HA identity.
- **Update** — appears instead of Assign when a known device reappears under a new UUID. Clicking it adds the UUID to the existing alias automatically.

Source badges indicate where each entry came from: **Device** (blue), **Item** (green), or **Friend** (purple). Family members that appear in both Devices and Friends are automatically deduplicated — they show up once as a Device with enriched data from both sources.


## Grouped Accessories

Some Apple accessories report as a parent device with sub-items (e.g. an AirPods Pro pair has Case, Left Bud, and Right Bud as children of the pair). The Unassigned list surfaces only the parent (e.g. "AirPods Pro") by default.

- **Parent rows show a small chevron pill** on the right. Click it to expand and see the sub-items indented underneath.
- **Sub-items are not posted to Home Assistant unless aliased.** The parent group entity is the canonical "AirPods" entry. To publish a specific bud (e.g. for finding a lost one), expand the parent and assign that sub-item like any other entry.
- **Parent location is automatically backfilled** from the freshest child when the parent's own location is stale, so the parent entity always reflects the most current known location.


## Aliases

Shows all created aliases. Use the filter menu to narrow by source type.

- **Tracked toggle** — only tracked aliases are posted to Home Assistant. Flip it off to keep an alias without posting.
- **Rename** (pencil icon) — changes the alias. This also changes the HA entity ID, so rename with care.
- **Delete** (trash icon) — removes the alias from the app. Does not remove anything from HA.
- **Copy name** (clipboard icon) — copies the device's original name.
- **Remove UUID** — click the X on any UUID to unlink it. If it's the last UUID on a tracked alias, you'll get a confirmation warning.


## How Identity Works

Each alias maps to a single HA entity using three derived fields:

- **`dev_id`** — `findmy_<alias>` — the HA entity identifier
- **`host_name`** — `findmy_<alias>` — matches `dev_id` so entity IDs align
- **`mac`** — derived from alias — stable ID that doesn't depend on rotating UUIDs

Battery percentage is included when available. `location_name` is intentionally omitted to preserve HA zone detection.

**MQTT users:** Entities are created automatically via Home Assistant auto-discovery — no manual configuration needed. Rich attributes (altitude, speed, course, motion state, location label) are published on each entity's `json_attributes_topic` when available.

**REST users:** Optionally edit `known_devices.yaml` in Home Assistant to add friendly names.


## UUID Rotation

Apple periodically rotates device and item UUIDs. When this happens:

1. The device appears in **Unassigned** with an **Update** button (matched by name).
2. Click **Update** to add the new UUID to the existing alias.
3. The HA entity stays the same — no disruption.

The app keeps the last N UUIDs per alias (configurable in General Settings) and automatically evicts older ones. If **Auto-learn UUIDs** is enabled, the app detects name matches and adds new UUIDs without manual intervention.


## Dry Run

Shows exactly what would be posted without actually sending to HA. Useful for verifying aliases and checking that rich attributes are present before going live.
