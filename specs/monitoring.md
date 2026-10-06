# Monitoring

The **Monitoring** tab puts what happened and who was seen on one screen
([lib/monitoring.dart](../presence_app/lib/monitoring.dart)). It replaced
the separate Events and Subjects tabs.

## The tab

- Second in the app bar, after **Camera** and before **Settings** (the
  `monitor_heart` icon, tooltip "Monitoring"; see
  [Navigation](navigation.md)).
- Swiping between tabs is off here: a sideways drag moves the map. Tap
  the tabs to leave.

## Layout

- **At the top,** one compact row (40 dp): on the left the **events
  search**, a search icon that opens into a field when tapped (see
  [Events](events.md)), its small **matching / all** event count beside
  it, and, only while the events show a single device's, a small chip
  with that device's ID and an x to show every device again.
- **Above each event's card,** the **device it was taken on**, small and
  quiet; tapping it shows only that device's events, on both the map and
  the events list (every device by default). See [Events](events.md).
- **At the bottom right,** under the events, a small **system events
  toggle**: an icon with no label (tooltip "Show system events" / "Hide
  system events"), on by default in DEV only; off, only grabs show.
- It fits a 320 dp phone without overflowing: the open search field gets
  narrower, and a long device ID is cut short in its chip.
- **Wide screens (720 dp and up), two columns:**
  - **left:** the **map of every subject's events** (only the device
    picked, if one is), in a rounded,
    outlined frame: each subject in its own color, the newest dot solid
    and older ones fading, and **the subject's name beside their newest
    dot**, in a pill edged in their color. It opens **centered on the
    newest event, zoomed out to show all of them**, with **zoom buttons**
    (see [Subjects](subjects.md#the-maps-view)). Tapping a name opens the
    subject's screen (their map and history of events; see
    [Subjects](subjects.md));
  - **right:** **all events**, newest first, as cards; a clip's card lists
    its **subjects, each with a square in their color** (see
    [Clips](clips.md)). The column is two fifths of the width, kept
    between 360 and 520 dp; the map takes the rest.
- **Phones (narrower):** the map (35% of the height) above the events.
- The page is padded 16 dp (12 dp on phones) at the top and sides, with
  the same gap between the map and the events, the system events toggle
  closing it at the bottom, and stops growing at 1600 dp, centered.
- There is no subjects list: subjects are reached through their names on
  the map, and seen on each event's card.
- With nobody tagged yet, the map shows the whole world without dots.

## Opening an event

- **Tapping a dot** on this map, or on a subject's map, shows its event in
  the events list here: any subject's screen closes, the Monitoring tab
  shows, and the list scrolls to the event and outlines it for 4 s. An
  event of a device other than the one picked shows every device again
  so it can show.
- Tapping the clip message pill over the camera opens this tab.

## Verified

- `monitoring_test.dart`: at 1500 dp the map is on the left and the
  events (520 dp) on the right, padded and 16 dp apart, from the same top;
  at 2400 dp the page stops at 1600 dp, centered; a clip card's 16:9
  thumbnail stays inside the events column; at 400 dp the map is above the
  events; a clip card shows its subject.
- `subjects_test.dart`: each clip card lists its subjects once, as
  written, in their colors, updating when a tag is added; the map has
  every subject's located dots in their colors, faded per subject, and a
  name only beside each subject's newest dot; tapping a name opens the
  subject's screen; on a 360 dp phone the map sits above the events; a dot
  tapped on a subject's screen closes it and outlines the event in this
  tab's list. `events_filter_test.dart`: each event shows its device,
  this device's in bold, and no chip at first; tapping another device's
  tag shows only its events (and the count drops), with its chip at the
  top, kept across tabs; the chip's x shows every device again; this
  device's tag shows its events (those published since launch too), and
  tapped again every device; a new event shows while filtered.
  `subjects_test.dart` also checks that tapping an event's device takes
  the other device's dots off the map and its events off the list, and
  the chip's x brings them back. `system_events_test.dart`: signed in
  (RBAC), only the clip shows until the system events toggle is turned on,
  and the choice stays across tabs; with no grabs, the hidden-events
  message; in DEV, system events show by default and hide when turned off.
  `events_search_test.dart`: the search is an icon top left (40 dp or
  more) with the count beside it; tapped, it opens focused; typing filters
  by title, detail, camera label, tags (not suggestions) and object tags,
  ignoring case; with text it stays open when unfocused, and emptied and
  unfocused it folds back; a search kept from before shows open, and
  folds when cleared elsewhere; a clip given object tags after the search
  was typed shows up; the x clears and folds it; it combines with the
  system events toggle; the toggle is a small icon at the bottom right,
  under the events, with no label, and toggles; at 320 and 390 dp the top
  row fits (one row, with the device chip and a long search) without
  overflow; the matching / all count follows the search, the filters, new
  events and late object tags; *all* leaves out other users' events and
  grows as events arrive from the cloud.
- Web release build compiles. Not yet tried in a browser with real tiles.

## Known limitations

- Names on the map can overlap when subjects were last seen close
  together.
- A subject with no located event has no name on the map, so their screen
  can't be opened from this tab.
