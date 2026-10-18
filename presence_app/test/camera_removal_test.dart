import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_removal.dart';
import 'package:presence_app/delete_device.dart';
import 'package:presence_app/l10n/gen/app_localizations.dart';

void main() {
  group('removeCamera', () {
    late Map<String, Map<String, Object?>> files;
    late List<(String, String, Map<String, Object?>)> sent;
    late List<String> reads;
    late bool sendWorks;

    setUp(() {
      files = {};
      sent = [];
      reads = [];
      sendWorks = true;
    });

    Future<CameraRemoval> remove(
      String device, {
      String? os,
      List<String> streamers = const ['calm_quiet_otter', 'odd_shy_fox'],
    }) => removeCamera(
      device,
      os: os,
      streamers: streamers,
      putFile: (streamer, name, json) async {
        if (!sendWorks) return false;
        sent.add((streamer, name, json));
        return true;
      },
      getFile: (streamer, name) async {
        reads.add('$streamer/$name');
        return files['$streamer/$name'];
      },
      now: DateTime.fromMillisecondsSinceEpoch(1000),
    );

    Map<String, Object?> listing(List<String> devices) => {
      'state': 'connected',
      'cameras': [
        for (final d in devices) {'name': d, 'deviceId': d},
      ],
    };

    test('a Blink camera: its remove goes to the streamer whose status '
        'lists it, not the other', () async {
      files['calm_quiet_otter/blink-status.json'] = listing(['zesty_owl']);
      files['odd_shy_fox/blink-status.json'] = listing(['brave_little_lamp']);
      expect(
        await remove('brave_little_lamp', os: 'Blink'),
        CameraRemoval.sent,
      );
      expect(sent.single.$1, 'odd_shy_fox');
      expect(sent.single.$2, 'blink.json');
      expect(sent.single.$3, {
        'remove': 'brave_little_lamp',
        'requestedAt': 1000,
      });
      // Only Blink's statuses are read.
      expect(reads, [
        'calm_quiet_otter/blink-status.json',
        'odd_shy_fox/blink-status.json',
      ]);
    });

    test('GoPro and Reolink cameras: their own integration', () async {
      files['calm_quiet_otter/gopro-status.json'] = listing(['gopro_cam']);
      files['calm_quiet_otter/reolink-status.json'] = listing(['reo_cam']);
      expect(await remove('gopro_cam', os: 'GoPro'), CameraRemoval.sent);
      expect(await remove('reo_cam', os: 'Reolink'), CameraRemoval.sent);
      expect(
        [for (final s in sent) (s.$1, s.$2, s.$3['remove'])],
        [
          ('calm_quiet_otter', 'gopro.json', 'gopro_cam'),
          ('calm_quiet_otter', 'reolink.json', 'reo_cam'),
        ],
      );
    });

    test('every streamer that lists it is told', () async {
      files['calm_quiet_otter/blink-status.json'] = listing(['cam']);
      files['odd_shy_fox/blink-status.json'] = listing(['cam']);
      expect(await remove('cam', os: 'Blink'), CameraRemoval.sent);
      expect([for (final s in sent) s.$1], ['calm_quiet_otter', 'odd_shy_fox']);
    });

    test('not a camera: nothing read, nothing sent', () async {
      expect(await remove('brave_phone', os: 'Android'), CameraRemoval.none);
      expect(reads, isEmpty);
      expect(sent, isEmpty);
    });

    test('a camera no streamer that answers lists: nothing to tell', () async {
      files['calm_quiet_otter/blink-status.json'] = listing(['zesty_owl']);
      expect(await remove('cam', os: 'Blink'), CameraRemoval.none);
      expect(sent, isEmpty);
    });

    test('no operating system known: every integration looked in, and only '
        'one found told', () async {
      files['odd_shy_fox/reolink-status.json'] = listing(['cam']);
      expect(await remove('cam'), CameraRemoval.sent);
      expect(sent.single.$2, 'reolink.json');
      sent.clear();
      // Nothing found, nothing answering: not said to come back.
      files.clear();
      expect(await remove('brave_phone'), CameraRemoval.none);
      expect(sent, isEmpty);
    });

    test("the streamer can't be told (its key not here yet): it may come "
        'back', () async {
      files['calm_quiet_otter/blink-status.json'] = listing(['cam']);
      sendWorks = false;
      expect(await remove('cam', os: 'Blink'), CameraRemoval.notSent);
    });

    test('no streamer answers (cloud sync off), or none at all: it may come '
        'back', () async {
      expect(await remove('cam', os: 'Blink'), CameraRemoval.notSent);
      expect(
        await remove('cam', os: 'GoPro', streamers: const []),
        CameraRemoval.notSent,
      );
    });

    test(
      'a read or a send that throws counts as not answered, not sent',
      () async {
        final result = await removeCamera(
          'cam',
          os: 'Blink',
          streamers: const ['calm_quiet_otter'],
          putFile: (_, _, _) async => throw StateError('offline'),
          getFile: (_, _) async => {
            'cameras': [
              {'deviceId': 'cam'},
            ],
          },
          now: DateTime(2026),
        );
        expect(result, CameraRemoval.notSent);
        final unread = await removeCamera(
          'cam',
          os: 'Blink',
          streamers: const ['calm_quiet_otter'],
          putFile: (_, _, _) async => true,
          getFile: (_, _) async => throw StateError('offline'),
          now: DateTime(2026),
        );
        expect(unread, CameraRemoval.notSent);
      },
    );
  });

  group('the delete dialog', () {
    Future<void> deleteWith(WidgetTester tester, DeviceDeleted result) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => deleteDeviceAfterConfirming(
                  context,
                  deviceId: 'brave_little_lamp',
                  events: 3,
                  delete: (_, {required events}) async => result,
                ),
                child: const Text('delete'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-device-keep')));
      await tester.pumpAndSettle();
    }

    testWidgets("a camera whose streamer couldn't be told: said it may come "
        'back', (tester) async {
      await deleteWith(tester, (events: 0, cameraMayReturn: true));
      expect(
        find.text('Removed brave_little_lamp from the list; its videos stay'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('delete-device-camera-not-told')),
        findsOneWidget,
      );
      expect(find.textContaining('it may come back'), findsOneWidget);
    });

    testWidgets('a camera told, or another device: nothing more said', (
      tester,
    ) async {
      await deleteWith(tester, (events: 0, cameraMayReturn: false));
      expect(
        find.text('Removed brave_little_lamp from the list; its videos stay'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('delete-device-camera-not-told')),
        findsNothing,
      );
    });
  });
}
