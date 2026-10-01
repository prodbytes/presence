# Monitoring

The **Monitoring** tab puts what happened and who was seen on one screen
([lib/monitoring.dart](../presence_app/lib/monitoring.dart)). It replaced
the separate Events and Subjects tabs.

## The tab

- Second in the app bar, after **Camera** and before **Device** (the
  `monitor_heart` icon, tooltip "Monitoring"; see
  [Navigation](navigation.md)).
- Swiping between tabs is off here, as on the Device tab: a sideways drag
  moves the map or the subjects strip. Tap the tabs to leave.

## Layout

- **Wide screens (720 dp and up), two columns:**
  - **left, on top:** the **map of every subject's events** (two fifths of
    the height), each subject in its own color, the newest dot solid and
    older ones fading (see [Subjects](subjects.md));
  - **left, below the map:** **all events**, newest first, with the
    **Only this device** checkbox at the top, checked by default (see
    [Events](events.md));
  - **right, the whole height (340 dp):** the **subjects**, one card per
    subject, the most recently seen first. Tapping a card opens the
    subject's screen (their map and history of events).
- **Phones (narrower), stacked:** the map (three tenths of the height),
  then the subjects as a **sideways strip** of 280 dp cards (a smaller
  frame and one line per text, so every card is the same height), then the
  events filling the rest.
- With nobody tagged yet, the map shows the whole world without dots, and
  the subjects area says "No subjects yet. Tag people and pets on a clip."
  (on one line in the strip).

## Opening an event

- **Tapping a dot** on this map, or on a subject's map, shows its event in
  the events list here: any subject's screen closes, the Monitoring tab
  shows, and the list scrolls to the event and outlines it for 4 s. An
  event of another device clears **Only this device** so it can show.
- The "View" action on a clip's snackbar opens this tab.

## Verified

- `subjects_test.dart`: on a wide screen the map is top left, the
  subjects to its right and the events under the map; on a 360 dp phone
  the map, the strip (horizontal, cards side by side) and the events stack
  without overflow; the tab sits between Camera and Device, and the Events
  and Subjects tabs are gone; a dot tapped on a subject's screen closes it
  and outlines the event in this tab's list. `widget_test.dart`: the tabs
  in order, and the tab shows the map, the subjects and the events. 202
  Flutter tests pass.
- Web release build compiles. Not yet tried in a browser with real tiles.

## Known limitations

- On a phone the events get what's left under the map and the strip:
  about half of a 740 dp screen.
