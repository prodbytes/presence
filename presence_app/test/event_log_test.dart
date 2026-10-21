import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/events.dart';

ClipRequested clip(
  String id,
  int minute, {
  String? profileId,
  ClipTrigger trigger = ClipTrigger.manual,
}) => ClipRequested(
  VideoClip.restored(
    id: 'clip-$id',
    cameraId: 'cam',
    cameraLabel: 'Back camera',
    before: const Duration(seconds: 15),
    after: const Duration(seconds: 15),
    past: null,
    full: null,
  ),
  trigger: trigger,
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

  test("a start's clip is a system event, hidden by default", () {
    final startup = clip(
      'start',
      1,
      profileId: 'me',
      trigger: ClipTrigger.startup,
    );
    log.addHistory([startup, clip('rex', 2, profileId: 'me')]);
    final filters = EventFilters(showSystemEvents: false);
    addTearDown(filters.dispose);
    EventView view() => filters.viewOf(log, deviceId: 'here', profileId: 'me');
    expect(view().shown.map((e) => e.id), ['rex']);
    filters.showSystemEvents.value = true;
    expect(view().shown.map((e) => e.id), ['rex', 'start']);
  });

  test('the clips with no one are hidden until shown; other events are '
      'not', () {
    ClipRequested seeing(String id, int minute, List<String>? labels) =>
        clip(id, minute, profileId: 'me')
          ..annotations.setObjects([
            for (final label in labels ?? const <String>[])
              ObjectTag(label: label, ms: 0, score: 0.9),
          ]);
    final empty = seeing('empty', 7, []);
    final named = seeing('named', 3, [])..annotations.add('Rex', 0.5, 0.5);
    log.addHistory([
      empty,
      seeing('person', 6, ['human', 'car']),
      seeing('cat', 5, ['cat']),
      seeing('bird', 4, ['bird']),
      seeing('truck', 8, ['truck']),
      named,
      // Not searched for objects yet: may have someone.
      clip('new', 2, profileId: 'me'),
      clip('start', 1, profileId: 'me', trigger: ClipTrigger.startup)
        ..annotations.setObjects(const []),
      system('door', 0)..profileId = 'me',
    ]);
    final filters = EventFilters(showEventsWithNoOne: false);
    addTearDown(filters.dispose);
    EventView view() => filters.viewOf(log, deviceId: 'here', profileId: 'me');
    List<String?> shown() => view().shown.map((e) => e.id).toList();

    // System events shown: they show, the start's clip with no one too.
    // Every animal counts, the bird too; a truck alone doesn't.
    expect(shown(), ['person', 'cat', 'bird', 'named', 'new', 'start', 'door']);
    expect(EventTimeline.hasSomeone(empty), isFalse);

    // With the system events toggle: only the grabs with someone.
    filters.showSystemEvents.value = false;
    expect(shown(), ['person', 'cat', 'bird', 'named', 'new']);

    // With the search: both must pass.
    filters.search.value = 'truck';
    expect(shown(), isEmpty);
    expect(view().ofKinds.map((e) => e.id), contains('truck'));
    filters.search.value = '';

    // Recognition seeing someone later: it shows.
    final first = view().withSomeone;
    expect(identical(view().withSomeone, first), isTrue);
    empty.annotations.setObjects([
      const ObjectTag(label: 'dog', ms: 0, score: 0.8),
    ]);
    expect(shown(), ['empty', 'person', 'cat', 'bird', 'named', 'new']);

    filters.showEventsWithNoOne.value = true;
    expect(shown(), [
      'truck',
      'empty',
      'person',
      'cat',
      'bird',
      'named',
      'new',
    ]);
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
