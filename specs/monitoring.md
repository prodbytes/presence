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
  [Events](events.md)), and its small **matching / all** event count
  beside it.
- **Above each event's card,** the **device it was taken on**, small and
  quiet; tapping it sets the search to the device's ID, which shows only
  that device's events, on both the map and the events list (every
  device by default); tapped again, the search clears. A device's name
  tapped anywhere else in the app (an event's details, the account
  sheet, the All grid) comes here the same way (see
  [Navigation](navigation.md)). See [Events](events.md).
- **In the same top row,** after the count, a small **system events
  toggle**: an icon with no label (tooltip "Show system events" / "Hide
  system events"), on by default in DEV only; off, only grabs show.
- It fits a 320 dp phone without overflowing: the open search field gets
  narrower.
- **Wide screens (720 dp and up), two columns:**
  - **left:** the **map of every subject's events** (the signed-in
    profile's only, and only the device searched for, if the search is a
    device's ID), in a rounded,
    outlined frame: each subject in its own color, the newest dot solid
    and older ones fading, and **the subject's name beside their newest
    dot**, in a pill edged in their color. It opens **on the newest
    event, close up at street level** (zoom 16–17, fitting only the dots
    within 300 m of it), once the events load too, and moves to each
    newer event until the map is moved by hand; then it stays put. It
    has **zoom buttons** (see [Subjects](subjects.md#the-maps-view)).
    Picking or clearing a device fits it again. Tapping a name opens the
    subject's screen (their map and history of events; see
    [Subjects](subjects.md));
  - **right:** **all events**, newest first, as cards; a clip's card lists
    its **subjects, each with a square in their color** (see
    [Clips](clips.md)). The column is 55% of the width, kept between 360
    and 880 dp; the map takes the rest. From 600 dp the clip cards put
    their thumbnail beside the details.
- **Phones (narrower):** the map (30% of the room under the filters, at
  least 160 dp unless that's over half of it) above the events; a very
  short page (a landscape phone with the keyboard open) doesn't overflow.
- The page is padded 16 dp (12 dp on phones) at the top and sides, with
  the same gap between the map and the events, and stops growing at
  1600 dp, centered.
- There is no subjects list: subjects are reached through their names on
  the map, and seen on each event's card.
- With nobody tagged yet, the map shows the whole world without dots.

## Opening an event

- **Tapping a dot** on this map, or on a subject's map, shows its event in
  the events list here: any subject's screen closes, the Monitoring tab
  shows, and the list scrolls to the event and outlines it for 4 s. An
  event of a device other than the one picked shows every device again
  so it can show.
- It's opened once (`EventFilters.focus`, a one-shot request): leaving
  the tab and coming back keeps the search and filters as they were
  left, and doesn't open the event again.
- Tapping the clip message pill over the camera opens this tab.

## Verified

- `monitoring_test.dart`: at 1500 dp the map is on the left and the
  events (55%, wider than the map) on the right, padded and 16 dp apart,
  from the same top; the events column is 396 dp at 720 dp and 880 dp at
  1600 dp; at 320, 390 and 1280 dp, and 640x100 dp, it fits without
  overflow, the stacked map 30% of the room under the filters; the stacked map's height is 30%, at least 160 dp,
  at most half; at 2400 dp the page stops at 1600 dp, centered; a clip card's 16:9
  thumbnail stays inside the events column; at 400 dp the map is above the
  events; a clip card shows its subject.
- `subjects_test.dart`: each clip card lists its subjects once, as
  written, in their colors, updating when a tag is added; the map has
  every subject's located dots in their colors, faded per subject, and a
  name only beside each subject's newest dot; it opens centered on the
  newest at zoom 16–17 with a dot 90 m away in view and one 30 km away
  out of it (a lone newest at zoom 17); it moves to the events once they
  load and to a newer one arriving, but not after being dragged, not even
  on a resize; a nearly antipodal dot is no trouble; tapping a name opens the
  subject's screen; on a 360 dp phone the map sits above the events; a dot
  tapped on a subject's screen closes it and outlines the event in this
  tab's list; opened once, a search typed since, Settings and back:
  the search and the system events toggle are kept, the event isn't
  outlined again, and nothing is changed during a build.
  `events_filter_test.dart`: each event shows its device,
  this device's in bold, with the "Show this device's events" tooltip;
  tapping another device's tag sets the search to its ID and shows only
  its events (and the count drops), kept across tabs; tapped again, the
  search clears and every device shows; this device's tag shows its
  events (those published since launch too); a new event shows while
  filtered; a whole device ID (any case) narrows to that device, part of
  one matches as text. `device_events_test.dart`: see
  [Navigation](navigation.md). `subjects_test.dart` also checks that
  tapping an event's device takes the other device's dots off the map and
  its events off the list, and the search's x brings them back. `system_events_test.dart`: signed in
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
  system events toggle; the toggle is a small icon in the top row,
  with the other filters, with no label, and toggles; at 320 and 390 dp the top
  row fits (one row, with a device's ID searched, then a long search) without
  overflow; the matching / all count follows the search, the filters, new
  events and late object tags; *all* leaves out other users' events and
  grows as events arrive from the cloud, and the timeline shows as many
  cards as the count (not another profile's event). Opening an event
  (`EventFilters.focus`) clears what hides it once: the tab rebuilt keeps
  the search and toggle set since; asked for before the tab is
  built it applies after the first frame; asked again it applies again.
  `widget_test.dart`: a new event scrolls the timeline up only when near
  the top; a sync with nothing new doesn't notify, and older or replaced
  events leave the list where it was scrolled. `event_log_test.dart`: the
  events snapshot, `eventsOf`, tag changes notifying `annotations` (not
  the log), the filter steps reused until a change, and the one-shot
  focus.
  `tag_filter_test.dart`: tapping a tag or a subject on a card sets the
  search to it, shows only the events with it, highlights it on every
  card shown, and doesn't open the player; tapping it again, or the
  search's x, clears both; tapping another replaces it; tapping one in the
  player opened from a card closes it on the filtered list, and shows it
  selected there next time; a long press on a card's label still opens
  the player where it was seen, a long press on a subject's chip in the
  player still renames, and the x still removes; it fits 320 dp; outside
  a timeline a click still opens the player.
- Web release build compiles. Not yet tried in a browser with real tiles.

## Known limitations

- Names on the map can overlap when subjects were last seen close
  together.
- A subject with no located event has no name on the map, so their screen
  can't be opened from this tab.
