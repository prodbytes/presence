# Subjects

The people and pets tagged on clips (see [Clips](clips.md), "Naming people
and pets"), each with where the device was when they were seen
([lib/subjects.dart](../presence_app/lib/subjects.dart)).

## Who is a subject

- Every **name tagged on a clip** is a subject, whether someone tagged it
  or [recognition](recognition.md) did; a recognition **suggestion** counts
  only once someone confirms it. Tags with the same name,
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
  with several subjects gets a dot for each. It **opens centered on the
  newest event** (of any subject) and **zoomed out just enough to show
  every dot** (the whole world without any; see [the map's
  view](#the-maps-view)), has the tiles' credit and **zoom buttons**, and
  tapping a dot opens its event in the Monitoring tab's events list.
- **Names on the map:** beside each subject's newest located dot, the
  subject's name in a dark pill edged in their color (up to 160 dp, cut
  short with an ellipsis). Tapping it opens the subject's screen.
- **On each clip's card** (`EventSubjects`): every subject tagged on it,
  once, as written there, each after a **square in the subject's color**,
  to match them with their dots on the map. Clicking a name opens the
  player paused at the earliest frame that subject is tagged on (see
  [Clips](clips.md)).

## The map's view

Both maps, the subjects map and a subject's own, open and zoom the same
way (`_SightingsMap`, [lib/subjects.dart](../presence_app/lib/subjects.dart)):

- **Centered on the newest event:** the newest dot shown, by event time,
  is in the middle of the map, not the middle of all the dots.
- **Zoomed out to catch them all:** as close as it can be with every dot
  in view, 48 px from the edges, at most zoom 17. Each dot's mirror image
  through the newest one, in the map's Web Mercator projection, is fitted
  along with the dots (`framedAround`), so the fit is centered exactly on
  the newest. The farthest dot from it sets the zoom.
- **Without a located event:** the whole world, at zoom 2.
- **Zoom in (+) over zoom out (−)** in the bottom-right corner
  (`MapZoomButtons`, shared with the Settings [location
  map](device-location.md); keys `sightings-zoom-in`, `sightings-zoom-out`).
  Each steps the zoom by one around the map's center, between zoom 2 and
  19; a button turns off at its limit. Pinch, wheel and drag still work.
- The view is set when the map opens; new events don't move it.

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
  - It opens centered on the subject's newest event, zoomed out to show
    all the dots, with zoom buttons: see [the map's view](#the-maps-view).
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
  match those colors, and a tapped dot opens its event; the map opens with
  the newest dot in its middle (not the middle of the three) and all dots
  in view, the farthest near the edge, and the zoom buttons double and
  halve the spacing of the dots; without located events, zoom out is off;
  `framedAround` centers the fit on the newest, and stops mirrors at the
  date line.
  `widget_test.dart`: the four tabs in order, and an admin's app bar fits
  on a 320 dp phone.
- Web release build compiles. Not yet tried in a browser with real tiles.

## Known limitations

- Near the date line, a mirror image is cut back to it, so the map may
  not be exactly centered on the newest event there.
- The view is set when a map opens: events added while it's open don't
  recenter it.

- Subjects are matched by name only: two people tagged with the same name
  are one subject, and one person tagged with two spellings is two.
- With seven colors, some subjects share one.
- The dots are where the **device** was, not the subject: every event from
  one fixed camera lands on the same spot.
- Only events in this device's history count (its own, and those synced
  from the cloud for the signed-in user).
