# Events

- Events appear on the [Monitoring](monitoring.md) tab, beside the subjects'
  map (under it on phones), in a vertically scrolling timeline, newest at the top. Each
  entry is just a card, with no dot or rail beside it, and cards are 8 px
  apart.
- Each event card shows an icon, a title, an optional detail line and the time
  (HH:mm:ss). Event types can supply their own card (`AppEvent.buildCard`);
  `ClipRequested` does, and so does `SubjectSuggestion`, the **"Is this
  Rex?"** question [recognition](recognition.md) asks, with Yes / No.
- **Search.** A **Search events** field (`EventSearch`) sits at the top
  left of the Monitoring tab, 220 dp wide, on the same row as the filter
  chips (before them); on a narrow phone the chips wrap onto the rows
  below it. Typing filters the timeline live, ignoring case and the spaces
  around the text: an event shows if its **title**, **detail**, **camera
  label** or, for a clip, **the name of someone tagged on it** or **one of
  its [object tags](recognition.md)** (`cat`, `bicycle`…) contains the
  text. Suggestions waiting for an answer aren't tags, so they don't
  match a clip; the "Is this Rex?" event matches through its own title,
  and its clip's camera label. An **x** in the field clears it; blank,
  every event shows, as before.
  - The search works together with the chips: an event shows only if it
    passes both. With nothing matching, the timeline says
    `No events match "<text>"`.
  - The text stays while switching tabs, but not across restarts.
  - **Opening an event the search hides** from elsewhere clears it, so the
    event can show.
  - **Counts.** Right after the field, on its row, the count of events
    (`EventCount`) reads **matching / all**, such as `2 / 12`, with the
    tooltip "2 of 12 events shown".
    - *All* is every event of the signed-in account's profile on this
      device (`EventTimeline.ofProfile`): recorded here, restored from
      storage, or fetched from the cloud (S3), so it grows as sync loads
      more. Events without a profile (recorded signed out, or not saved
      yet) count too, since the next sign-in gives them its profile. Other
      profiles' events left on the
      device don't count.
    - *Matching* is those events left after the search and both chips,
      using the timeline's own filter steps (`EventTimeline.ofDevices`,
      `ofKinds`, `matching`).
    - Both numbers update with new events, sync, the chips, the search,
      tags recognition adds later, and sign-in or sign-out. On a narrow phone
      the field gets narrower so the count stays beside it.
  - What's searched is one function, `eventSearchFields` (used by
    `eventMatches`) in [lib/events.dart](../presence_app/lib/events.dart);
    a new searchable field is one more line there.
  - While searching, the list also matches again whenever a clip's tags
    or object tags change, so a clip recognition tags after the search was
    typed shows up then.
- **Only this device, by default.** An **Only this device** filter chip
  (`ThisDeviceOnly`) sits at the top of the Monitoring tab, checked at
  launch: the timeline shows only
  events whose `deviceId` is this device's (events not saved yet, which
  have no device ID, count as this device's). Clearing it shows every
  device's events, such as those fetched from the cloud. The choice stays
  while switching tabs, but not across restarts. The chip appears once
  the device ID is known; before that, every event shows.
  - Filtered with nothing left, the timeline says "No events on this
    device".
  - **Opening an event of another device** from elsewhere (see below)
    clears the chip, so the event can show.
- **Show system events: on in DEV, off otherwise.** A **Show system
  events** filter chip (`ShowSystemEvents`), after Only this device,
  decides which events show:
  - **on:** every event, such as **Application started**, sign-ins and
    sign-outs, the recording consent and other plain events;
  - **off:** only **grabs**, the clip events (`ClipRequested`: Clip
    requested, Motion detected, Scheduled clip, Startup clip, Capture
    all), the [Capture all](camera.md#capture-all) requests
    (`capture_all`), and the
    [recognition](recognition.md) suggestions about them ("Is this Rex?",
    `SubjectSuggestion`), which wait for an answer.
  - It starts on in [DEV](execution-mode.md) and off in RBAC, decided once
    the execution mode is known. The choice stays while switching tabs, but
    not across restarts. It always shows, even before the device ID is
    known.
  - Off, with only system events left, the timeline says "No grabs yet:
    system events are hidden".
  - **Opening a hidden system event** from elsewhere turns it on, so the
    event can show.
  - It only filters the timeline: every event is still saved and synced.
- When a new event arrives, the timeline scrolls back to the top to show it.
- **Opening an event from elsewhere** (a dot on a [subject's](subjects.md)
  map) switches to the Monitoring tab, scrolls the timeline to that event and
  outlines its card in the accent color for 4 s (`EventTimeline.focus`).
  Cards far down the list aren't built yet, so the timeline first jumps to
  where the card should be, from the average card height, until it's
  built (up to 8 tries), then scrolls it into view.
- On launch, the app pushes an **Application started** event.
- Every event carries the **device** it was recorded on (`deviceId`) and
  the **profile** it belongs to (`profileId`, none until a sign-in gives
  it one), and who was signed in (`userId`, or `anonymous`). See
  [Devices, users and places](devices-users-places.md).
- With no events, the panel shows a "No events" empty state.
- Events flow through an app-wide **event bus**: a plain Dart broadcast
  `StreamController` (`AppEventBus` in
  [lib/events.dart](../presence_app/lib/events.dart)). Any widget can publish
  with `AppEventBusScope.of(context).publish(event)`, and any number of
  listeners can subscribe to `bus.stream`.
- The bus keeps no history. `EventLog` subscribes to it at startup and holds
  the history the timeline shows. The app owns both, above `MaterialApp`, so
  every screen and route can reach the bus. The startup event is published
  only after `EventLog` subscribes; otherwise it would be dropped.
