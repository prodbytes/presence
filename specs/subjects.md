# Subjects

The people and pets tagged on clips (see [Clips](clips.md), "Naming people
and pets"), each with where the device was when they were seen
([lib/subjects.dart](../presence_app/lib/subjects.dart)).

## Who is a subject

- Every **name tagged on a clip** is a subject. Tags with the same name,
  ignoring case and surrounding spaces, are the same subject ("Rex" and
  " rex "). The name shows as written on the latest event.
- A subject's **events** are the clip events (`ClipRequested`) with that
  name tagged, one per event even when tagged twice on it, newest first.
- They're worked out from the event history in memory (`subjectsOf`):
  restored, synced from the cloud and new events alike. Nothing extra is
  stored. Adding, renaming or removing a tag updates both screens at once.

## On the Monitoring tab

- Subjects show on the [Monitoring](monitoring.md) tab, on the map and on
  the events' cards; there is no subjects list.
- **The subjects map** merges every subject's
  events: for each subject, a dot per event among their latest
  `mapEvents` that has a location, in **the subject's color**, the newest
  solid and older ones fading, as on a subject's own map. A clip tagged
  with several subjects gets a dot for each. It opens on all the dots (the
  whole world without any), has the tiles' credit, and tapping a dot opens
  its event in the Monitoring tab's events list.
- **Names on the map:** beside each subject's newest located dot, the
  subject's name in a dark pill edged in their color (up to 160 dp, cut
  short with an ellipsis). Tapping it opens the subject's screen.
- **On each clip's card** (`EventSubjects`): every subject tagged on it,
  once, as written there, each after a **square in the subject's color**,
  to match them with their dots on the map.

## A subject's screen

- A full screen pushed over the tabs (back returns to Monitoring), titled
  with the subject's name.
- **The map** (top three fifths): OpenStreetMap tiles with the credit, as on
  the Settings [location map](device-location.md), north up. **One dot per event**
  at the location the event recorded.
  - **Color = subject**: every dot, and the dot on the subject's frames
    here and in the Subjects list, is in the **subject's color**
    (`Subject.color`): one of Gruvbox's red, blue, green, yellow, purple,
    aqua and orange, picked from the subject's name. A name always gets
    the same color, on every screen, launch and platform.
  - **Opacity = age**: the **newest dot is fully opaque**; older ones fade
    evenly by rank, down to 15 % for the oldest shown. Newer dots are
    drawn over older ones.
  - **Tapping a dot opens its event on the Monitoring tab**: the subject's
    screen closes, the Monitoring tab shows, and its events list scrolls to the
    event and outlines it for 4 s (see [Events](events.md)). A dot's
    tooltip and screen-reader label give its time and camera.
  - It opens fitted on all the dots (48 px padding, at most zoom 17), or
    on the whole world (zoom 2) when none has a location.
- **The list** (below the map): "Latest 20 of 26 events" (or "26 events"
  when all are shown), then each event, newest first: its frame, time and
  camera, the coordinates (5 decimals) or "No location", and the same
  dot, in the same color and opacity, as on the map. Tapping an event in the list plays its clip.
- **It shows the latest 20 events by default**, set on the Settings screen
  (**Latest events on a subject's map**, 5–100 in steps of 5;
  `SubjectsConfig.mapEvents`, see [Configuration](configuration.md)).
  Changing it updates an open screen.
- Events without a location (published before the location was known, or
  with location unavailable) are listed but have no dot.
- If every tag of the subject is removed while the screen is open, it says
  "Nobody is tagged with this name any more."

## Verified

- `subjects_test.dart`: names grouped ignoring case, one event per clip,
  newest first, with the latest frame; the opacity runs from 1 to 0.15;
  the setting's default, range and round-trip, and old configs without it;
  a clip card's subjects and colors, updating when a tag is added; a
  subject's screen with the latest 20 of 26 dots, fading, then 25
  after raising the setting, and the event without a location listed with
  no dot; a subject's color depends only on its name and spreads over
  the palette, and every dot has it, fading by age; the setting's slider;
  the Monitoring tab between Camera and Settings; tapping a dot far down the
  timeline closes the subject's screen, shows the Monitoring tab with that
  event on screen and outlined, and the outline goes after 4 s; the
  subjects map (left of the events) has every subject's located dots (one
  per subject on a shared clip) in each subject's color, faded per
  subject, a name beside each subject's newest dot, the cards' squares
  match those colors, and a tapped dot opens its event.
  `widget_test.dart`: the four tabs in order, and an admin's app bar fits
  on a 320 dp phone.
- Web release build compiles. Not yet tried in a browser with real tiles.

## Known limitations

- Subjects are matched by name only: two people tagged with the same name
  are one subject, and one person tagged with two spellings is two.
- With seven colors, some subjects share one.
- The dots are where the **device** was, not the subject: every event from
  one fixed camera lands on the same spot.
- Only events in this device's history count (its own, and those synced
  from the cloud for the signed-in user).
