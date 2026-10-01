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

- **At the top:** the **Only this device** filter chip (checked by
  default; shown once the device ID is known), then the **Show system
  events** chip (checked by default in DEV only: off, only grabs show). See
  [Events](events.md).
- **Wide screens (720 dp and up), two columns:**
  - **left:** the **map of every subject's events**, in a rounded,
    outlined frame: each subject in its own color, the newest dot solid
    and older ones fading, and **the subject's name beside their newest
    dot**, in a pill edged in their color. Tapping a name opens the
    subject's screen (their map and history of events; see
    [Subjects](subjects.md));
  - **right:** **all events**, newest first, as cards; a clip's card lists
    its **subjects, each with a square in their color** (see
    [Clips](clips.md)). The column is two fifths of the width, kept
    between 360 and 520 dp; the map takes the rest.
- **Phones (narrower):** the map (35% of the height) above the events.
- The page is padded 16 dp (12 dp on phones), with the same gap between
  the map and the events, and stops growing at 1600 dp, centered.
- There is no subjects list: subjects are reached through their names on
  the map, and seen on each event's card.
- With nobody tagged yet, the map shows the whole world without dots.

## Opening an event

- **Tapping a dot** on this map, or on a subject's map, shows its event in
  the events list here: any subject's screen closes, the Monitoring tab
  shows, and the list scrolls to the event and outlines it for 4 s. An
  event of another device clears **Only this device** so it can show.
- The "View" action on a clip's snackbar opens this tab.

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
  tab's list. `events_filter_test.dart`: the Only this device chip filters
  and keeps its state across tabs. `system_events_test.dart`: signed in
  (RBAC), only the clip shows until Show system events is checked, and the
  choice stays across tabs; with no grabs, the hidden-events message; in
  DEV, system events show by default and hide when cleared. 215 Flutter
  tests pass.
- Web release build compiles. Not yet tried in a browser with real tiles.

## Known limitations

- Names on the map can overlap when subjects were last seen close
  together.
- A subject with no located event has no name on the map, so their screen
  can't be opened from this tab.
