# Monitoring

The **Monitoring** tab puts what happened and who was seen on one screen
([lib/monitoring.dart](../presence_app/lib/monitoring.dart)). It replaced
the separate Events and Subjects tabs.

## The tab

- Second in the app bar, after **Camera** and before **Device** (the
  `monitor_heart` icon, tooltip "Monitoring"; see
  [Navigation](navigation.md)).
- Swiping between tabs is off here, as on the Device tab: a sideways drag
  moves the map. Tap the tabs to leave.

## Layout

Two rows, on every screen size:

- **First row (45% of the height), two columns:**
  - **left:** the **map of every subject's events**, each subject in its
    own color, the newest dot solid and older ones fading (see
    [Subjects](subjects.md));
  - **right:** the **subjects**, one card per subject, one under the other,
    the most recently seen first (340 dp wide, or 45% of the width on
    narrower screens). Tapping a card opens the subject's screen (their map
    and history of events). In a column narrower than 260 dp, a card puts
    the frame above the name and details instead of beside them.
- **Second row, only events:** **all events**, newest first, one card per
  row, as before (see [Events](events.md)), with the **Only this device**
  checkbox at the top, checked by default. The cards are at most 640 dp
  wide, centered, so a clip's 16:9 thumbnail stays shorter than the row.
- With nobody tagged yet, the map shows the whole world without dots, and
  the subjects column says "No subjects yet. Tag people and pets on a clip."

## Opening an event

- **Tapping a dot** on this map, or on a subject's map, shows its event in
  the events list here: any subject's screen closes, the Monitoring tab
  shows, and the list scrolls to the event and outlines it for 4 s. An
  event of another device clears **Only this device** so it can show.
- The "View" action on a clip's snackbar opens this tab.

## Verified

- `subjects_test.dart`: on a 360 dp phone and a 1280 dp screen, the map
  and the subjects share the first row side by side (subjects stacked
  vertically), and the events fill the second row, full width, as cards one
  under the other, without overflow; the tab sits between Camera and
  Device, and the Events and Subjects tabs are gone; a dot tapped on a
  subject's screen closes it and outlines the event in this tab's list.
  `widget_test.dart`: the tabs in order, and the tab shows the map, the
  subjects and the events. 204 Flutter tests pass.
- Web release build compiles. Not yet tried in a browser with real tiles.

## Known limitations

- On a phone the subjects column is narrow (about 160 dp), so each card
  shows the frame above a wrapped name and details.
