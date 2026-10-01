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

## The Subjects tab

- A tab between **Events** and **Device** (the `people` icon, tooltip
  "Subjects"; see [Navigation](navigation.md)), at the same 560 px readable
  width as Events.
- One card per subject, the **most recently seen first**:
  - the **frame** the subject was tagged on in their latest event, 96 px
    wide at its own shape, with a dot in the subject's color where they
    were clicked. A tag
    without a frame shows the clip's thumbnail instead (no dot);
  - the name;
  - "Last seen 14:03:22 · Back camera": the event's time (with the date,
    `2026-09-30 08:05:00`, when it isn't today) and camera;
  - how many events they're on ("3 events").
- With no tags yet: "No subjects yet. Tag people and pets on a clip."
- Tapping a card opens the subject's screen.

## A subject's screen

- A full screen pushed over the tabs (back returns to Subjects), titled
  with the subject's name.
- **The map** (top three fifths): OpenStreetMap tiles with the credit, as on
  the [Device](device-location.md) tab, north up. **One dot per event**
  at the location the event recorded.
  - **Color = subject**: every dot, and the dot on the subject's frames
    here and in the Subjects list, is in the **subject's color**
    (`Subject.color`): one of Gruvbox's red, blue, green, yellow, purple,
    aqua and orange, picked from the subject's name. A name always gets
    the same color, on every screen, launch and platform.
  - **Opacity = age**: the **newest dot is fully opaque**; older ones fade
    evenly by rank, down to 15 % for the oldest shown. Newer dots are
    drawn over older ones.
  - **Tapping a dot opens its event in the Events tab**: the subject's
    screen closes, the Events tab shows, and the timeline scrolls to the
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
  the list's order, frames and "Last seen" line, updating when a tag is
  added; a subject's screen with the latest 20 of 26 dots, fading, then 25
  after raising the setting, and the event without a location listed with
  no dot; a subject's color depends only on its name and spreads over
  the palette, and every dot has it, fading by age; the setting's slider;
  the tab between Events and Device; tapping a dot far down the timeline
  closes the subject's screen, shows the Events tab with that event on
  screen and outlined, and the outline goes after 4 s.
  `widget_test.dart`: the five tabs in order, and an admin's app bar fits
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
