import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/clips.dart';
import 'package:presence_app/event_details.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/storage/records.dart';

const profile = 'automatic_paranoid_axolotl';

/// A clip from the Blink camera "Garden", its own device.
ClipRequested gardenClip({
  String id = 'garden-1',
  String? cameraName = 'Garden',
  String device = 'pungent_orbital_canal',
}) =>
    ClipRequested(
        VideoClip.restored(
          id: 'clip-$id',
          cameraId: 'blink',
          cameraLabel: 'Garden',
          before: Duration.zero,
          after: const Duration(seconds: 30),
          past: null,
          full: null,
        ),
        trigger: ClipTrigger.motion,
        id: id,
        deviceId: device,
        profileId: profile,
        time: DateTime(2026, 10, 18, 9),
      )
      ..os = 'Blink'
      ..cameraName = cameraName;

void main() {
  group('the camera name', () {
    test('round-trips through the record, with when it was stored', () {
      final e = gardenClip()..storedAt = DateTime(2026, 10, 18, 12);
      final record = e.toRecord();
      expect(record['cameraName'], 'Garden');
      expect(
        record['storedAt'],
        DateTime(2026, 10, 18, 12).millisecondsSinceEpoch,
      );
      expect(AppEvent.cameraNameOf(record), 'Garden');
      expect(AppEvent.storedAtOf(record), DateTime(2026, 10, 18, 12));
      final phone = AppEvent(
        icon: Icons.circle,
        title: 'Door opened',
        detail: 'Back camera',
        deviceId: 'brave_quiet_lamp',
      )..os = 'Android';
      expect(phone.toRecord(), isNot(contains('cameraName')));
      expect(phone.toRecord(), isNot(contains('storedAt')));
    });

    test("a fetched camera's older event (no cameraName) has its detail; "
        "a phone's or a streamer's own camera none", () {
      Map<String, Object?> record(String os, {Object? name}) => {
        'id': 'e',
        'time': 0,
        'detail': 'Garden',
        'os': os,
        'cameraName': ?name,
      };
      for (final os in ['Blink', 'GoPro', 'Reolink']) {
        expect(AppEvent.cameraNameOf(record(os)), 'Garden', reason: os);
      }
      expect(AppEvent.cameraNameOf(record('Linux')), isNull);
      expect(AppEvent.cameraNameOf(record('Android')), isNull);
      expect(AppEvent.cameraNameOf(record('Linux', name: 'Porch')), 'Porch');
      expect(AppEvent.cameraNameOf(record('Blink', name: ' ')), isNull);
    });

    test('a record from the bucket: a camera name that isn\'t text, or a '
        'stored time that isn\'t a number, is dropped', () {
      final clean = Records.tryParseEvent({
        'id': 'e',
        'time': 1,
        'cameraName': 7,
        'storedAt': 'soon',
      })!;
      expect(clean, isNot(contains('cameraName')));
      expect(clean, isNot(contains('storedAt')));
      expect(
        Records.tryParseEvent({
          'id': 'e',
          'time': 1,
          'storedAt': 5,
        })!['storedAt'],
        5,
      );
    });
  });

  group('the event card', () {
    late EventLog log;
    late EventFilters filters;

    setUp(() {
      log = EventLog(const Stream.empty());
      filters = EventFilters();
    });
    tearDown(() {
      log.dispose();
      filters.dispose();
    });

    Future<void> show(
      WidgetTester tester,
      List<AppEvent> events, {
      double width = 800,
      double textScale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      log.addHistory(events);
      await tester.pumpWidget(
        EventDetailsScope(
          profileId: profile,
          deleteEvent: (e) async => true,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(
              body: EventTimeline(
                log: log,
                filters: filters,
                profileId: profile,
                deviceId: 'brave_quiet_lamp',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('names the camera before its device, "Garden | device"; '
        'tapped, it shows that device\'s events', (tester) async {
      final other = gardenClip(
        id: 'phone-1',
        cameraName: null,
        device: 'brave_quiet_lamp',
      )..os = 'Android';
      await show(tester, [gardenClip(), other]);
      expect(
        find.descendant(
          of: find.byKey(const Key('event-device-garden-1')),
          matching: find.text('Garden | pungent_orbital_canal'),
        ),
        findsOneWidget,
      );
      // No camera name: the device alone, as before.
      expect(
        find.descendant(
          of: find.byKey(const Key('event-device-phone-1')),
          matching: find.text('brave_quiet_lamp'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('event-device-garden-1')));
      await tester.pump();
      expect(filters.search.value, 'pungent_orbital_canal');
      expect(find.byKey(const Key('event-device-phone-1')), findsNothing);
    });

    for (final (width, scale) in [(1200.0, 1.0), (320.0, 2.0)]) {
      testWidgets('every button together at the top right, in one row '
          '(${width.toInt()} dp, ${scale}x text)', (tester) async {
        await show(tester, [gardenClip()], width: width, textScale: scale);
        expect(tester.takeException(), isNull);
        final card = tester.getRect(find.byKey(const Key('feed-card')));
        final row = tester.getRect(
          find.byKey(const Key('event-actions-garden-1')),
        );
        final buttons = [
          for (final key in [
            'event-recognition-garden-1',
            'event-cloud-garden-1',
            'event-copies-garden-1',
            'event-delete-garden-1',
          ])
            tester.getRect(find.byKey(Key(key))),
        ];
        // At the card's right edge, in its header, above the event's card.
        expect(card.right - row.right, lessThanOrEqualTo(8));
        expect(row.right, lessThanOrEqualTo(width));
        final body = tester.getRect(
          find.byKey(const Key('clip-card-thumbnail')),
        );
        for (final b in buttons) {
          expect(row.contains(b.center), isTrue);
          expect(b.bottom, lessThanOrEqualTo(body.top));
        }
        // Side by side, in order, with no room between them but their own.
        for (var i = 1; i < buttons.length; i++) {
          expect(buttons[i].left - buttons[i - 1].right, lessThanOrEqualTo(4));
          expect(buttons[i].center.dy, closeTo(buttons[0].center.dy, 1));
        }
        // The device gives way, on the left.
        final device = tester.getRect(
          find.byKey(const Key('event-device-garden-1')),
        );
        expect(device.right, lessThanOrEqualTo(row.left));
        expect(device.left - card.left, lessThanOrEqualTo(16));
      });
    }
  });

  testWidgets('the details name the camera before the device', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EventDevice(event: gardenClip())),
      ),
    );
    expect(find.text('Garden |'), findsOneWidget);
    final name = tester.getRect(
      find.byKey(const Key('event-device-camera-name')),
    );
    final id = tester.getRect(find.byKey(const Key('event-device-id')));
    expect(name.right, lessThan(id.left));
  });
}
