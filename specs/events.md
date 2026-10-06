# Events

- Events appear on the [Monitoring](monitoring.md) tab, beside the subjects'
  map (under it on phones), in a vertically scrolling timeline, newest at the top. Each
  entry is just a card, with no dot or rail beside it, and cards are 8 px
  apart.
- Each event card shows an icon, a title, an optional detail line and the time
  (HH:mm:ss). Event types can supply their own card (`AppEvent.buildCard`);
  `ClipRequested` does, and so does `SubjectSuggestion`, the **"Is this
  Rex?"** question [recognition](recognition.md) asks, with Yes / No.
- An event can carry **[flags](event-flags.md)** (`AppEvent.flags`),
  worked out from its data and shown on its card: a clip showing a person
  or pet nobody's named has a yellow **unidentified** flag, with
  **Identify** to name them.
- **Search.** The events search (`EventSearch`) sits at the top left of
  the Monitoring tab, in one compact row with the count and the device
  filter chip. It's a **search icon button** (tooltip "Search events")
  until tapped; tapped, it opens into a **Search events** field (up to
  280 dp, narrower on a small phone), focused so the keyboard comes up.
  It folds back into the icon when it loses focus empty, when submitted
  empty, or with the **x** in the field, which clears it first; while it
  has text it stays open (and shows open when coming back to the tab with
  a search kept). Typing filters the timeline live, ignoring case and the spaces
  around the text: an event shows if its **title**, **detail**, **camera
  label** or, for a clip, **the name of someone tagged on it** or **one of
  its [object tags](recognition.md)** (`cat`, `bicycle`…) or **one of its
  [flags](event-flags.md)** (`unidentified`) contains the
  text. Suggestions waiting for an answer aren't tags, so they don't
  match a clip; the "Is this Rex?" event matches through its own title,
  and its clip's camera label. Blank, every event shows.
  - The search works together with the device filter and the system
    events toggle: an event shows only if it passes all three. With nothing matching, the timeline says
    `No events match "<text>"`.
  - The text stays while switching tabs, but not across restarts.
  - **Opening an event the search hides** from elsewhere clears it, so the
    event can show (and the field folds back, unless it's focused).
  - **Counts.** Right after the search (icon or field), on its row, the count of events
    (`EventCount`) reads **matching / all**, such as `2 / 12`, with the
    tooltip "2 of 12 events shown".
    - *All* is every event of the signed-in account's profile on this
      device (`EventTimeline.ofProfile`): recorded here, restored from
      storage, or fetched from the cloud (S3), so it grows as sync loads
      more. Events without a profile (recorded signed out, or not saved
      yet) count too, since the next sign-in gives them its profile. Other
      profiles' events left on the
      device don't count.
    - *Matching* is those events left after the search and both filters,
      using the timeline's own filter steps (`EventTimeline.ofDevices`,
      `ofKinds`, `matching`).
    - Both numbers update with new events, sync, the filters, the
      search, tags recognition adds later, labels removed with their x on
      a card, and sign-in or sign-out. On a narrow phone the open field
      gets narrower so the count stays beside it.
  - What's searched is one function, `eventSearchFields` (used by
    `eventMatches`) in [lib/events.dart](../presence_app/lib/events.dart);
    a new searchable field is one more line there.
  - While searching, the list also matches again whenever a clip's tags
    or object tags change, so a clip recognition tags after the search was
    typed shows up then.
- **Every device, by default; tap an event's device to see only it.**
  Above each event's card, small and quiet, is the **device it was taken
  on** (`EventDeviceTag`): a device icon and the device ID, this device's
  in bold (events not saved yet, which have no device ID, are this
  device's; before the device ID is known they have no tag). Its tooltip
  says "Show only <device>".
  - The icon is the event's **operating system**'s (`DeviceOs.iconOf`:
    Android, iPhone, Mac laptop, Windows desktop, a computer for Linux, a
    globe for the web), and after the ID comes its name, as in
    `brave_quiet_lamp · Android`. Both shrink with an ellipsis on a
    narrow phone (the ID gets three fifths of the room). Events saved
    before events recorded an OS show the generic device icon and no
    name.
  - **Tapping it** shows only that device's events
    (`EventTimeline.onlyDevice`, `EventTimeline.ofDevices`) on the
    timeline, the [subjects map](subjects.md) and the count; the tag of
    the device shown turns the accent color, and tapping it again shows
    every device.
  - While one device is shown, a small chip with its ID and an **x**
    (`DeviceFilterChip`, tooltip "Show every device") sits in the top row
    after the count; tapping it or its x shows every device again. With
    every device shown there's no chip.
  - Every device shows at launch, including devices whose events arrive
    later (such as those fetched from the cloud). The choice stays while
    switching tabs, but not across restarts.
  - Filtered with nothing left (say, the search hides that device's
    events), the timeline says "No events on <device>".
  - **Opening an event of another device** from elsewhere (see below)
    shows every device again, so the event can show.
  - It replaced the devices dropdown (a checkbox per device and an All
    devices line).
- **Show system events: on in DEV, off otherwise.** A small, discreet
  **toggle icon** (`ShowSystemEvents`, a dimmed gear outline, the accent
  color filled while on; no label, its tooltip says "Show system events"
  or "Hide system events"; a 40 dp target) in the Monitoring tab's
  **top row**, after the count, with the other filters, decides which events show:
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
- Every event also records the **operating system** of the device that
  recorded it (`os`, set when it's published, `DeviceOs.current` in
  [lib/identity/device_os.dart](../presence_app/lib/identity/device_os.dart)):
  `Android`, `iOS`, `macOS`, `Windows` or `Linux` in the apps (from
  `Platform.operatingSystem`), and on the web the browser and the system
  under it from the user agent, such as `Web (Chrome, macOS)`
  (`Web` alone when neither is recognized). Browsers on iOS are named by
  their own token, not as Safari (`CriOS` Chrome, `FxiOS` Firefox,
  `EdgiOS` Edge, `OPT` Opera), and Edge and Opera elsewhere not as
  Chrome. iPadOS Safari presents itself as a Mac, so a Mac user agent on
  a touch screen (`navigator.maxTouchPoints` above 1) is taken for iOS.
  No version is recorded. It
  is saved with the event and syncs in its [JSON](data-formats.md), so
  other devices show it too; events saved before it have none, and keep
  none.
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
