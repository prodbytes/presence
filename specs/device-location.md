# Device location and battery

Where each device is: shown and set on a map in the **Location** section
of Settings, and recorded on every event. The device's battery shows over
the camera. (There used to be a Device tab for both; it's gone.)

## The Location section of Settings

- A section of the [Settings screen](settings.md), after Subjects and
  before the version, device ID and health lines
  ([lib/location/location_settings.dart](../presence_app/lib/location/location_settings.dart)).
  The device ID isn't repeated here: Settings already shows it at the
  bottom.
- First, under a small label, the **Position (latitude, longitude)** (6
  decimals, selectable), then where it came from:
  - "This device's location · ±12 m": the device's own position, with the
    accuracy it reported;
  - "Set on the map": set by hand;
  - "Finding this device…" while the first reading is under way;
  - otherwise the reason, such as "Location permission was denied. Move
    the map to set it.", while the location is unknown. If a later reading
    fails, the location in force stays and the reason shows under it.
- Under it, **the map**, full width with rounded corners: `flutter_map`
  with OpenStreetMap tiles (no API key), credited "© OpenStreetMap
  contributors" in its bottom-left corner (shared with the
  [Subjects](subjects.md) maps:
  [lib/location/map_parts.dart](../presence_app/lib/location/map_parts.dart)).
  North stays up. It's **40 % of the screen's height, between 200 and
  320 px**, so on a phone there's room around it to scroll the list.
- A **red pin** is fixed at the center of the map. Its tip is the device's
  location.
- **Zoom in (+) and Zoom out (−)**, then a small **My location** button,
  in the map's bottom-right corner. Each zoom button steps the zoom by one
  level around the center, between 2 (the world) and 19, and turns off at
  its limit; zooming keeps the center, so it doesn't set the location. My
  location asks the device for its position again; it spins while
  waiting, and the map moves to the answer (zoom 17, or closer if already
  zoomed in).
- With no location yet, the map opens on the whole world (zoom 2).
- **A drag on the map moves the map**: while a finger (or the mouse) is
  down on it, the Settings list doesn't scroll and the tabs don't swipe
  (`onMapHeld`). Elsewhere in Settings, both work as usual.

## Battery, over the camera

- Over the Camera tab, **bottom left**, across from Flip and Clip, in the
  same pill style as the readiness indicator
  ([lib/battery_pills.dart](../presence_app/lib/battery_pills.dart),
  [lib/status_pill.dart](../presence_app/lib/status_pill.dart)); see
  [Navigation](navigation.md) for the layout. Only with access, like the
  camera's buttons.
- **Battery pill:** "82 %" with an icon: `battery_charging_full` while
  charging, `battery_full` when full, otherwise a bar icon from empty to
  full for the level. Below 15 % and not charging, a warning icon
  (`battery_alert`) and the label in the error color. Its tooltip and
  screen-reader label say "Battery 82 %, charging" (or "full", "on
  battery", "plugged in, not charging"). **Hidden when there's no
  reading.**
- Read through **`battery_plus`** ([lib/battery.dart](../presence_app/lib/battery.dart)):
  the platform's battery on Android and iOS (no permission needed), and
  the browser's **Battery Status API** (`navigator.getBattery()`) on the
  web. Chrome and Edge have it; Firefox and Safari don't, so there's no
  pill there. In those browsers the plugin answers 0 % with an unknown
  state; that's taken as no reading, not an empty battery.
- `BatteryController`, owned by the home screen, reads it at launch, again
  when charging starts or stops (the plugin's event), and **every minute**
  (level changes have no event).
- **Temperature pill** (Android only): "31.5 °C" with a thermometer icon,
  in the error color from 45 °C up. It's the battery's temperature, which
  Android reports in tenths of a degree on the sticky
  `ACTION_BATTERY_CHANGED` broadcast (`EXTRA_TEMPERATURE`, no
  permission), read through the app's own `presence/device` channel
  (`batteryTemperature` in `MainActivity`) with each battery reading.
  **iOS** has no public API for a temperature in degrees (only a coarse
  thermal state) and **browsers** have none, so there's no pill there,
  nor when Android doesn't report one.
- The battery isn't stored or sent with events.

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
  unknown; damaged records read as none. In the app:
  - there's no Device tab; the Location section shows the pin, the
    labeled position, the accuracy and the credit, without the device ID;
  - Settings is full width (the map spans 1280 px less the 16 px
    margins);
  - the zoom buttons step the zoom, keep the device's own location, and
    Zoom in turns off at the closest zoom;
  - dragging the map sets the location, moves neither the list nor the
    tabs, events before and after carry the device's and the map's, the
    choice survives a restart, and My location asks again;
  - without permission the section asks for a move and events have no
    location;
  - the battery pill shows over the camera only, follows a charging change
    at once and a level drop within a minute, warns below 15 %, says
    "full", and is hidden without a reading; the temperature pill shows
    to one decimal, turns to the error color from 45 °C, and is hidden
    where it isn't reported;
  - on a 320 dp phone and a 1280 px desktop, the pills sit bottom left
    and touch neither Flip nor Clip: stacked above the buttons' row on
    the phone, level with them on the desktop.
- Web release and Android debug builds compile. The battery and its
  temperature haven't been read on a phone, nor in a browser, yet.

## Known limitations

- No battery in Firefox and Safari (no Battery Status API). On a desktop
  without a battery, Chrome reports 100 % and charging.
- OpenStreetMap's public tile server is meant for light use and needs the
  credit shown; heavy use would need another tile provider.
- The location is read once per launch; a moving device isn't followed.
