import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/events.dart';

ClipRequested clip(String id, int minute, {String? profileId}) => ClipRequested(
  VideoClip.restored(
    id: 'clip-$id',
    cameraId: 'cam',
    cameraLabel: 'Back camera',
    before: const Duration(seconds: 15),
    after: const Duration(seconds: 15),
    past: null,
    full: null,
  ),
  annotations: ClipAnnotations(),
  time: DateTime(2026, 10, 6, 12, minute),
  id: id,
)..profileId = profileId;

AppEvent system(String id, int minute) => AppEvent(
  icon: Icons.circle,
  title: 'Door opened',
  time: DateTime(2026, 10, 6, 12, minute),
  id: id,
);

void main() {
  late StreamController<AppEvent> bus;
  late EventLog log;
  setUp(() {
    bus = StreamController<AppEvent>.broadcast();
    log = EventLog(bus.stream);
  });
  tearDown(() {
    log.dispose();
    bus.close();
  });

  test('events is a snapshot, made once per change', () async {
    log.addHistory([clip('a', 1), system('b', 2)]);
    final first = log.events;
    expect(identical(log.events, first), isTrue);
    expect(() => first.add(system('x', 0)), throwsUnsupportedError);

    final version = log.version;
    bus.add(system('c', 3));
    await Future<void>.delayed(Duration.zero);
    expect(log.version, version + 1);
    // The one taken before stays as it was.
    expect(first.map((e) => e.id), ['b', 'a']);
    expect(log.events.map((e) => e.id), ['c', 'b', 'a']);
  });

  test("eventsOf keeps the profile's events until the log changes", () {
    log.addHistory([
      clip('mine', 1, profileId: 'me'),
      clip('theirs', 2, profileId: 'them'),
      clip('nobody', 3),
    ]);
    final mine = log.eventsOf('me');
    expect(mine.map((e) => e.id), ['nobody', 'mine']);
    expect(identical(log.eventsOf('me'), mine), isTrue);
    log.remove({'nobody'});
    expect(log.eventsOf('me').map((e) => e.id), ['mine']);
  });

  test('a tag change notifies annotations, not the log', () {
    final a = clip('a', 1);
    log.addHistory([a]);
    var changes = 0;
    var tags = 0;
    log.addListener(() => changes++);
    log.annotations.addListener(() => tags++);
    final version = log.annotationsVersion;

    a.annotations.add('Rex', 0.5, 0.5);
    expect(tags, 1);
    expect(changes, 0);
    expect(log.annotationsVersion, version + 1);

    // Gone from the log: no longer followed.
    log.remove({'a'});
    a.annotations.add('Ana', 0.5, 0.5);
    expect(tags, 1);
  });

  test('the filters share one pass, worked out again only on a change', () {
    final rex = clip('rex', 2, profileId: 'me');
    log.addHistory([rex, system('door', 1)..profileId = 'me']);
    final filters = EventFilters(showSystemEvents: false);
    addTearDown(filters.dispose);
    EventView view() => filters.viewOf(log, deviceId: 'here', profileId: 'me');

    final first = view();
    expect(first.mine, hasLength(2));
    expect(first.shown.map((e) => e.id), ['rex']);
    expect(identical(view().shown, first.shown), isTrue);

    // Searching: matched again when the tags change.
    filters.search.value = 'milo';
    expect(view().shown, isEmpty);
    expect(identical(view().ofKinds, first.ofKinds), isTrue);
    rex.annotations.add('Milo', 0.5, 0.5);
    expect(view().shown.map((e) => e.id), ['rex']);

    filters.showSystemEvents.value = true;
    filters.search.value = '';
    expect(view().shown.map((e) => e.id), ['rex', 'door']);
  });

  test('focus is a one-shot request', () {
    final filters = EventFilters();
    addTearDown(filters.dispose);
    var asked = 0;
    filters.focusRequests.addListener(() => asked++);
    expect(filters.takeFocus(), isNull);
    filters.focus('door');
    expect(asked, 1);
    expect(filters.takeFocus(), 'door');
    expect(filters.takeFocus(), isNull);
    // Again, even the same event: a new request.
    filters.focus('door');
    expect(filters.takeFocus(), 'door');
  });
}
