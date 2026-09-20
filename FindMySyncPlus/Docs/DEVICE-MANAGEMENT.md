# Device Management

The Device Manager maps what Find My reports to stable Home Assistant identities. Each entry has a badge for what it is: **Device** for iPhones, iPads, Macs and Watches, **Item** for AirTags and other trackers, **Friend** for people sharing their location with you, and **Group** for an accessory Apple tracks as a set of pieces, such as an AirPods pair.


## Unassigned

This list shows the entries from the last sync that have no alias yet. The filter menu limits it to Devices, Items or Friends.

- **Assign** opens a sheet with the alias prefilled from the entry's name. Letters, numbers, hyphens and underscores are allowed, and the app normalizes the alias when you save it. From then on that alias is the entry's Home Assistant identity.
- **Update** is shown in place of Assign when an entry's name matches an alias you already have but its UUID is new, which means Apple has rotated the identifier. Clicking it adds the new UUID to the existing alias.

A family member who appears both as a Device and as a Friend is listed once, as a Device, with the Friend data merged in.


## Grouped accessories

Apple tracks some accessories as a group of pieces. An AirPods pair is a Case, a Left Bud and a Right Bud. The group is listed as one entry with a **Group** badge; click the chevron beside the badge to show the pieces.

- **Assigning the group** works as it does for a device. The group remains in the Unassigned list with an **Assigned** pill, so you can still expand it and assign a piece.
- **The app publishes a piece only when you assign it.** The group is the Home Assistant entity for the pair, and a piece on its own is useful when you want to find a lost bud or watch its battery. The group has no battery reading of its own; each piece has one.
- **The group's location** is Apple's own reading for the group when there is one. Otherwise the app uses the location of the piece with the newest reading, except while the pieces are apart, when it uses the Case's, which gives a separated pair one steady location.

On MQTT the group's entity has three attributes for the source of its location:

- **`position_source`** is the piece whose location the group is using, such as `Case`, or `self` when Apple located the group directly.
- **`separation_status`** is `together`, `separated`, or `unknown` when a piece's last reading is too old to compare.
- **`pieces`** is each piece's address and the age of that location, present only while `separation_status` is `separated`.


## Aliases

This list shows the aliases you have created, with a filter menu by source. Each row shows the name Find My last reported, the entity ID with a copy button, and the known UUIDs.

- **Tracked** controls whether the app publishes the alias at all. Switch it off to keep the alias without publishing; on MQTT the app then removes the entity from the broker.
- **Rename** (the pencil icon) changes the alias. That creates a new Home Assistant entity ID, and the app runs a sync afterward so Home Assistant sees the new entity.
- **Re-create entity** (the circling arrows, MQTT only) removes the entity and creates it again so Home Assistant assigns its ID from the alias. Any rename, icon or area you set for it in Home Assistant is cleared, and recorded history remains under the old entity ID.
- **Delete** (the trash icon) removes the alias and its UUIDs from the app. On MQTT the app clears the entity and its last location from the broker on the next sync. On REST the Home Assistant entity is left alone.
- **Remove a UUID** by clicking the ⨉ on its chip. The app asks for confirmation before removing the last UUID from a tracked alias, since the alias then has no identifier to publish under until you add a new one.

Grouped accessories are nested here too. Once the group is assigned, its assigned pieces are listed under the group's own row. Until then they are listed under a header with the group's name, a **Group** badge and a **Not aliased** pill. The header is only a label; assigning still happens in Unassigned. After you delete a group's alias, its pieces are listed under a header again.


## How identity works

An alias of `kitchen-keys` becomes the device ID `findmy_kitchen-keys`, and Home Assistant names the entity `device_tracker.findmy_kitchen_keys`. The hyphen becomes an underscore because an entity ID allows only letters, numbers and underscores. Since the entity is named from the alias, it is unaffected when Apple changes its identifiers.

**MQTT.** Home Assistant discovery creates the entities for you, under one FindMySync+ device. Each entity has the location's attributes: when it was recorded (`location_timestamp`, `last_update`, `is_old`), its source (`position_type`, `is_inaccurate`), then `altitude`, `vertical_accuracy`, `speed`, `course` and `address` where Apple reports them. Battery is `battery` (a percentage, where the device has one), `battery_level_raw`, `battery_status_raw`, `charging_state`, and `battery_low` on Apple items. Items also have `role` and `role_emoji`, friends `motion_state` and `location_label`, and groups the three attributes above. A device with a real battery level also has a battery sensor.

**REST.** The app posts each tracked alias to `device_tracker/see` with `dev_id` and `host_name` both set to `findmy_<alias>`, a `mac` derived from the alias, `gps`, `gps_accuracy`, and `battery` where the device has one. It leaves `location_name` out, and Home Assistant works out the zone from the coordinates. Friendly names are set in `known_devices.yaml` in Home Assistant. The alias row shows the MAC the app will use.


## UUID rotation

Apple changes device and item identifiers from time to time. When that happens the entry is listed in Unassigned with an **Update** button, matched by name, and clicking it adds the new UUID to the alias; the entity is unchanged. The app keeps the most recent UUIDs per alias, up to the **Maximum UUIDs tracked** setting in General, and removes the oldest. With **Auto-learn UUIDs** on, the app applies a name match without the click.


## Dry Run

In a dry run the app reads and decrypts as usual, skips publishing, and logs what it would have published under each alias, so you can check aliases and attributes before going live.
