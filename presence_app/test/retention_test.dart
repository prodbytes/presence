import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';

import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/settings.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';
import 'package:presence_app/storage/retention.dart';

void main() {
  group('Persistence.deleteEventsBefore', () {
    test('deletes old events with their clips, recordings and '
        'suggestions', () async {
      final now = DateTime.now();
      int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
      final bus = AppEventBus();
      final persistence = Persistence(
        factory: Future.value(newIdbFactoryMemory()),
        bus: bus,
        config: ConfigController(),
        mediaStore: IdbMediaStore.new,
      );
      addTearDown(() {
        persistence.dispose();
        bus.close();
      });
      final store = await persistence.store;
      Future<void> clip(String id, String eventId, int time) async {
        await store.putEvent({
          'id': eventId,
          'type': 'clipRequested',
          'title': 'Clip requested',
          'time': time,
          'clipId': id,
        });
        await store.putClip({
          'id': id,
          'eventId': eventId,
          'cameraId': 'cam',
          'beforeMs': 5000,
          'afterMs': 10000,
          'state': 'complete',
          'full': {'mediaId': '$id-full', 'startMs': 0, 'endMs': 15000},
        });
        await store.putMedia('$id-full', Uint8List.fromList([1, 2, 3]));
      }

      Future<void> event(String id, int time, [Map<String, Object?>? more]) =>
          store.putEvent({
            'id': id,
            'type': AppEvent.genericType,
            'title': 'Door opened',
            'time': time,
            ...?more,
          });

      await clip('c-old', 'old-clip', ago(const Duration(days: 20)));
      await clip('c-new', 'new-clip', ago(const Duration(days: 1)));
      await event('old-door', ago(const Duration(days: 15)));
      await event('door', ago(const Duration(days: 13)));
      // Recent, but about the old clip: it goes with it.
      await event('ask', ago(const Duration(hours: 1)), {
        'type': 'subject_suggestion',
        'clipEventId': 'old-clip',
      });

      // What cloud sync remembers of them: uploads and ETags, under the
      // current layout and the old one, and the device's settings.
      const p = 'us-east-1:identity';
      const deletedKeys = [
        '$p/events/year=2026/day=001/old-clip.json',
        'etag:$p/events/year=2026/day=001/old-clip.json',
        '$p/events/old-door.json',
        '$p/events/year=2026/day=001/ask.json',
        '$p/media/c-old.webm',
        '$p/media/c-old.jpg',
        '$p/media/c-old/frames/f1.jpg',
        '$p/clips/year=2026/day=001/c-old.json',
        '$p/clips/c-old.webm',
        '$p/clips/c-old/frames/f1.jpg',
      ];
      const keptKeys = [
        '$p/events/year=2026/day=001/door.json',
        'etag:$p/events/year=2026/day=001/new-clip.json',
        '$p/media/c-new.webm',
        '$p/clips/year=2026/day=001/c-new.json',
        '$p/devices/old-clip/settings.json',
      ];
      for (final key in [...deletedKeys, ...keptKeys]) {
        await store.markSynced(key, 'x');
      }

      final log = EventLog(bus.stream);
      addTearDown(log.dispose);
      await persistence.restore(log);
      expect(log.events, hasLength(5));

      final deleted = await persistence.deleteEventsBefore(
        now.subtract(const Duration(days: 14)),
      );

      expect(deleted, 3);
      expect(
        (await store.allEvents()).map((e) => e['id']),
        unorderedEquals(['new-clip', 'door']),
      );
      expect((await store.allClips()).map((c) => c['id']), ['c-new']);
      expect(await store.mediaIds(), ['c-new-full']);
      expect((await store.syncedKeys()).keys, unorderedEquals(keptKeys));
      expect(
        log.events.map((e) => e.id),
        unorderedEquals(['new-clip', 'door']),
      );

      // Nothing more to delete.
      expect(
        await persistence.deleteEventsBefore(
          now.subtract(const Duration(days: 14)),
        ),
        0,
      );
    });
  });

  group('EventRetention', () {
    testWidgets('runs at start, then every 3 h, with the current setting', (
      tester,
    ) async {
      final now = DateTime(2026, 10, 2, 12);
      final config = ConfigController();
      final cutoffs = <DateTime>[];
      final retention = EventRetention(
        delete: (cutoff) async {
          cutoffs.add(cutoff);
          return 0;
        },
        config: config,
        now: () => now,
      )..start();
      addTearDown(retention.dispose);
      await tester.pump();
      // Two weeks by default.
      expect(cutoffs, [DateTime(2026, 9, 18, 12)]);

      // A new setting waits for the next run.
      config.update(
        (c) => c.copyWith(
          history: c.history.copyWith(keep: const Duration(days: 1)),
        ),
      );
      await tester.pump(const Duration(hours: 2, minutes: 59));
      expect(cutoffs, hasLength(1));
      await tester.pump(const Duration(minutes: 1));
      expect(cutoffs.last, DateTime(2026, 10, 1, 12));
      await tester.pump(EventRetention.defaultEvery);
      expect(cutoffs, hasLength(3));

      retention.dispose();
      await tester.pump(EventRetention.defaultEvery);
      expect(cutoffs, hasLength(3));
    });

    test('one run at a time', () async {
      var calls = 0;
      final retention = EventRetention(
        delete: (_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 2;
        },
        config: ConfigController(),
      );
      final first = retention.run();
      final second = retention.run();
      expect(identical(first, second), isTrue);
      expect(await first, 2);
      expect(calls, 1);
      await retention.run();
      expect(calls, 2);
    });

    test('a failed run reports nothing deleted and allows the next', () async {
      var calls = 0;
      final retention = EventRetention(
        delete: (_) async {
          calls++;
          if (calls == 1) throw StateError('storage error');
          return 1;
        },
        config: ConfigController(),
      );
      expect(await retention.run(), 0);
      expect(await retention.run(), 1);
    });
  });

  testWidgets('the History slider keeps events a day to 90 days', (
    tester,
  ) async {
    final config = ConfigController();
    tester.view.physicalSize = const Size(600, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsView(config: config)),
      ),
    );
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Keep events for'), findsOneWidget);
    expect(find.text('2 weeks'), findsOneWidget);

    final slider = find.descendant(
      of: find.byKey(const Key('history-keep-slider')),
      matching: find.byType(Slider),
    );
    await tester.drag(slider, const Offset(-1000, 0));
    await tester.pump();
    expect(config.history.keep, const Duration(days: 1));
    expect(find.text('1 day'), findsOneWidget);
    await tester.drag(slider, const Offset(1000, 0));
    await tester.pump();
    expect(config.history.keep, const Duration(days: 90));
    expect(find.text('90 days'), findsOneWidget);
  });

  test('formatKeep', () {
    expect(formatKeep(const Duration(days: 1)), '1 day');
    expect(formatKeep(const Duration(days: 3)), '3 days');
    expect(formatKeep(const Duration(days: 7)), '1 week');
    expect(formatKeep(const Duration(days: 14)), '2 weeks');
    expect(formatKeep(const Duration(days: 30)), '30 days');
    expect(formatKeep(const Duration(days: 56)), '8 weeks');
    expect(formatKeep(const Duration(days: 63)), '63 days');
    expect(formatKeep(const Duration(days: 90)), '90 days');
  });
}
