# Events

- Events appear on the [Monitoring](monitoring.md) tab, under the subjects'
  map, in a vertically scrolling timeline, newest at the top. Each
  entry is just a card, with no dot or rail beside it, and cards are 8 px
  apart.
- Each event card shows an icon, a title, an optional detail line and the time
  (HH:mm:ss). Event types can supply their own card (`AppEvent.buildCard`);
  `ClipRequested` does.
- **Only this device, by default.** An **Only this device** checkbox sits
  at the top of the timeline, checked at launch: the timeline shows only
  events whose `deviceId` is this device's (events not saved yet, which
  have no device ID, count as this device's). Clearing it shows every
  device's events, such as those fetched from the cloud. The choice stays
  while switching tabs, but not across restarts. The checkbox appears once
  the device ID is known; before that, every event shows.
  - Filtered with nothing left, the timeline says "No events on this
    device" under the checkbox.
  - **Opening an event of another device** from elsewhere (see below)
    clears the checkbox, so the event can show.
- When a new event arrives, the timeline scrolls back to the top to show it.
- **Opening an event from elsewhere** (a dot on a [subject's](subjects.md)
  map) switches to the Monitoring tab, scrolls the timeline to that event and
  outlines its card in the accent color for 4 s (`EventTimeline.focus`).
  Cards far down the list aren't built yet, so the timeline first jumps to
  where the card should be, from the average card height, until it's
  built (up to 8 tries), then scrolls it into view.
- On launch, the app pushes an **Application started** event.
- Every event carries the **device** it was recorded on (`deviceId`) and
  the **user** it belongs to (`userId`, or `anonymous` until a user signs
  in and takes it over). See [Devices, users and
  places](devices-users-places.md).
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
