# Device location

Where each device is: shown on a map on the **Device** tab, and recorded
on every event.

## The Device tab

- A tab between **Subjects** and **Settings** (the `place` icon, tooltip
  "Device"; see [Navigation](navigation.md)). It shows a full-page map
  ([lib/location/device_view.dart](../presence_app/lib/location/device_view.dart)):
  `flutter_map` with OpenStreetMap tiles (no API key), credited
  "© OpenStreetMap contributors" in the bottom-left corner (shared with
  the [Subjects](subjects.md) maps:
  [lib/location/map_parts.dart](../presence_app/lib/location/map_parts.dart)). The map can't be
  rotated; north stays up.
- A **red pin** is fixed at the center of the map. Its tip is the device's
  location.
- A **card at the top** shows, each under a small label saying what it is,
  the **Device ID** (selectable) and the **Position (latitude,
  longitude)** (6 decimals, selectable), then where the position came
  from:
  - "This device's location · ±12 m": the device's own position, with the
    accuracy it reported;
  - "Set on the map": set by hand;
  - "Finding this device…" while the first reading is under way;
  - otherwise the reason, such as "Location permission was denied. Move
    the map to set it.", while the location is unknown. If a later reading
    fails, the location in force stays and the reason shows under it.
- **My location** (a button at the bottom right) asks the device for its
  position again. It spins while waiting, and the map moves to the answer
  (zoom 17, or closer if already zoomed in).
- **Zoom in (+) and Zoom out (−)** buttons sit above My location. Each
  steps the zoom by one level around the center, between 2 (the world)
  and 19, and turns off at its limit. Zooming keeps the center, so it
  doesn't set the location (the pin stays on the same spot).
- With no location yet, the map opens on the whole world (zoom 2).
- **Swiping between tabs is off on this tab**: a sideways drag moves the
  map. Tap the tabs to leave.

## Finding the location

- The device's own positioning, through `geolocator`, at the **best
  accuracy** it offers: GPS on phones, the browser's Geolocation API on web
  (which needs HTTPS or localhost). A reading gives up after 30 s.
- The permission is asked the first time it's needed: at launch, unless
  the location was set on the map. Location turned off or permission
  denied leaves it unknown; nothing else in the app changes.
  - Android: `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` in the
    manifest.
  - iOS: `NSLocationWhenInUseUsageDescription` ("Presence shows where this
    device is on a map and records it with each event.").
- It's read **once per launch**, not tracked: a phone carried around
  keeps the launch position until **My location** is pressed.

## Setting it on the map

- **Moving the map sets the location**: 0.4 s after a drag, fling or zoom
  by the user settles, the center of the map becomes the device's
  location, marked "Set on the map". Moves the app makes (recentering on a
  reading) don't count. Zooming around a point other than the center moves
  the center too, and so the location.
- A location set on the map **is kept**: across restarts the device isn't
  asked again, until **My location** is pressed. A reading that answers
  after the map was moved is dropped, so it never undoes the move.
- Longitudes past the date line are wrapped back into -180..180.

## Storage

- `LocationController`
  ([lib/location/device_location.dart](../presence_app/lib/location/device_location.dart))
  holds the location in force, and saves each new one in the `settings`
  store under `location` (see [Storage](storage.md)):

  | Field | Value |
  |---|---|
  | `lat`, `lng` | degrees (WGS 84) |
  | `accuracy` | meters, for the device's own readings only |
  | `source` | `device` (its positioning) or `map` (set by hand) |
  | `time` | when it was read or set, ms since the epoch |

## On every event

- Every event records the location in force **when it's published**, in
  the same form, as `location` on `AppEvent`, in the stored record and in
  the cloud event JSON (see [Devices, users and places](devices-users-places.md)
  and [Cloud sync](cloud-sync.md)). It's absent while the location is
  unknown, which includes the launch's "Application started" event: it's
  published before the saved location has loaded.
- Moving the map later doesn't change past events.

## Verified

- `device_location_test.dart`: a launch reads the device and saves it; a
  location set on the map survives a restart without asking the device,
  until My location; a saved device reading is read again at launch; a
  map move during a slow reading wins; a denied permission leaves it
  unknown; damaged records read as none. In the app: the tab sits between
  Events and Settings and shows the pin, coordinates, accuracy, device ID
  and credit; the card labels the device ID and the position; the zoom
  buttons step the zoom, keep the device's own location, and Zoom in
  turns off at the closest zoom; dragging the map sets the location, events before and after
  carry the device's and the map's, the choice survives a restart, and My
  location asks again; without permission the card asks for a move and
  events have no location.
- Web release and Android debug builds compile with the new plugins. Not
  yet tried on a phone or in a browser with real positioning and tiles.

## Known limitations

- OpenStreetMap's public tile server is meant for light use and needs the
  credit shown; heavy use would need another tile provider.
- The location is read once per launch; a moving device isn't followed.
- On 320 dp phones, the five tabs leave little room: the title shortens to
  an ellipsis.
