import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';

import 'fakes.dart';
import 'motion_test.dart' show frame;

void main() {
  late IdbFactory storage;

  setUp(() => storage = newIdbFactoryMemory());

  // The clock the app sees; tests may move it.
  late DateTime clock;
  setUp(() => clock = DateTime(2026, 9, 25, 12));

  Future<void> launch(
    WidgetTester tester, {
    List<FakeCameraSource> cameras = const [],
    CloudBackend? cloud,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        // A new key forces a fresh app, like a page reload.
        key: UniqueKey(),
        cameras: openFakes(cameras),
        storage: storage,
        mediaIo: fakeMediaIo,
        now: () => clock,
        auth: FakeAuthService.signedIn(),
        cloud: cloud,
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
    await tester.pumpAndSettle();
  }

  /// Closes the app and opens it again on the same storage.
  Future<void> refresh(
    WidgetTester tester, {
    List<FakeCameraSource> cameras = const [],
  }) async {
    await tester.pumpWidget(const SizedBox());
    await settleStorage(tester);
    await launch(tester, cameras: cameras);
  }

  /// Runs a storage call to completion under fake time.
  Future<T> run<T>(WidgetTester tester, Future<T> future) async {
    var done = false;
    late T result;
    Object? error;
    future.then(
      (v) {
        result = v;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    );
    for (var i = 0; i < 50 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (error != null) throw error!;
    expect(done, isTrue, reason: 'storage call timed out');
    return result;
  }

  Finder inEvents(Finder f) =>
      find.descendant(of: find.byKey(const Key('events-page')), matching: f);

  Future<void> pressClip(WidgetTester tester) => clipAndShowEvents(tester);

  ClipRequested clipEvent(WidgetTester tester) =>
      tester.widget<ClipEventCard>(find.byType(ClipEventCard)).event;

  const past = ClipMedia(
    url: 'blob:past',
    start: Duration(seconds: 2),
    end: Duration(seconds: 17),
  );
  const full = ClipMedia(
    url: 'blob:full',
    start: Duration(seconds: 10),
    end: Duration(seconds: 40),
  );

  testWidgets('events survive a refresh, newest first', (tester) async {
    await launch(tester);
    AppEventBusScope.of(tester.element(find.byType(Scaffold)))
        .publish(AppEvent(icon: Icons.circle, title: 'Door opened'));
    await tester.pumpAndSettle();
    await settleStorage(tester);

    await refresh(tester);
    await showEvents(tester);

    expect(inEvents(find.text('Application started')), findsNWidgets(2));
    expect(inEvents(find.text('Door opened')), findsOneWidget);
    // The new launch's startup event is on top, above the restored history.
    final tops = [
      for (final e in find.byType(Text).evaluate())
        if (e.widget case Text(data: 'Application started' || 'Door opened'))
          (e.widget as Text).data,
    ];
    expect(tops, ['Application started', 'Door opened', 'Application started']);
  });

  testWidgets('a finished clip survives a refresh, with its video', (
    tester,
  ) async {
    final camera = FakeCameraSource('Front door');
    await launch(tester, cameras: [camera]);
    await pressClip(tester);
    camera.pastCompleters.single.complete(past);
    await settleStorage(tester);
    camera.fullCompleters.single.complete(full);
    await settleStorage(tester);

    await refresh(tester, cameras: [camera]);
    await showEvents(tester);

    expect(inEvents(find.text('Clip requested')), findsOneWidget);
    expect(inEvents(find.text('Front door')), findsOneWidget);
    expect(inEvents(find.text('30 s clip ready')), findsOneWidget);
    expect(inEvents(find.byKey(const Key('clip-thumbnail'))), findsOneWidget);

    final clip = clipEvent(tester).clip;
    expect(clip.full!.start, full.start);
    expect(clip.full!.end, full.end);
    // Stored recordings are loaded from IndexedDB when played.
    expect(await run(tester, clip.full!.resolveUrl()), 'restored:blob:full');
  });

  testWidgets('signed in, a finished clip and its events upload to the cloud', (
    tester,
  ) async {
    final cloud = FakeCloudBackend();
    final camera = FakeCameraSource('Front door');
    await launch(tester, cameras: [camera], cloud: cloud);
    await pressClip(tester);
    camera.pastCompleters.single.complete(past);
    await settleStorage(tester);
    camera.fullCompleters.single.complete(full);
    await settleStorage(tester);
    await settleStorage(tester);

    final clipId = clipEvent(tester).clip.id;
    final prefix = 'us-east-1:identity';
    expect(cloud.tokens, isNotEmpty);
    // The full recording (its stored bytes), thumbnail and details.
    final video = cloud.uploads['$prefix/clips/$clipId.webm'];
    expect(video, isNotNull);
    expect(String.fromCharCodes(video!.bytes), 'blob:full');
    expect(cloud.uploads, contains('$prefix/clips/$clipId.jpg'));
    expect(cloud.uploads, contains('$prefix/clips/$clipId.json'));
    // Every event, the clip's included.
    final events = cloud.uploads.keys.where(
      (k) => k.startsWith('$prefix/events/'),
    );
    expect(events.length, greaterThanOrEqualTo(2));

    // The account sheet says so.
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('cloud-sync-status')),
        matching: find.textContaining('Backed up'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('after sign-in, clips from the cloud join the history', (
    tester,
  ) async {
    final cloud = FakeCloudBackend();
    const prefix = 'us-east-1:identity';
    Uint8List json(Map<String, Object?> m) =>
        Uint8List.fromList(utf8.encode(jsonEncode(m)));
    final requested = DateTime(2026, 9, 24, 8).millisecondsSinceEpoch;
    cloud.uploads['$prefix/clips/remote-clip.json'] = (
      bytes: json({
        'id': 'remote-clip',
        'eventId': 'remote-event',
        'cameraId': 'garage-cam',
        'cameraLabel': 'Garage',
        'requestedAt': requested,
        'beforeMs': 15000,
        'afterMs': 15000,
        'supported': true,
        'state': 'complete',
        'full': {
          'mediaId': 'remote-clip-full',
          'startMs': 0,
          'endMs': 30000,
          'mimeType': 'video/webm',
        },
      }),
      contentType: 'application/json',
    );
    cloud.uploads['$prefix/clips/remote-clip.webm'] = (
      bytes: Uint8List.fromList('remote-video'.codeUnits),
      contentType: 'video/webm',
    );
    cloud.uploads['$prefix/events/remote-event.json'] = (
      bytes: json({
        'id': 'remote-event',
        'type': ClipRequested.clipRequestedType,
        'title': 'Clip requested',
        'time': requested,
        'cameraId': 'garage-cam',
        'clipId': 'remote-clip',
        'clipState': 'complete',
        'trigger': 'manual',
      }),
      contentType: 'application/json',
    );

    await launch(tester, cloud: cloud);
    await settleStorage(tester);
    await settleStorage(tester);
    await tester.pumpAndSettle();
    await showEvents(tester);

    expect(inEvents(find.text('Garage')), findsOneWidget);
    // The downloaded recording plays from local storage.
    final restored = clipEvent(tester).clip;
    expect(restored.id, 'remote-clip');
    expect(
      await run(tester, restored.full!.resolveUrl()),
      'restored:remote-video',
    );
  });

  testWidgets(
    'tags: a clicked frame, positions and names saved with the event',
    (tester) async {
      ClipPlayerController.debugCaptureOverride = () async => CapturedFrame(
        jpeg: onePixelPng,
        position: const Duration(milliseconds: 7400),
      );
      addTearDown(() => ClipPlayerController.debugCaptureOverride = null);
      final camera = FakeCameraSource('Front door');
      await launch(tester, cameras: [camera]);
      await pressClip(tester);
      camera.pastCompleters.single.complete(past);
      await settleStorage(tester);
      camera.fullCompleters.single.complete(full);
      await settleStorage(tester);

      await tester.tap(inEvents(find.byKey(const Key('clip-play'))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nobody tagged yet'), findsOneWidget);

      // Grab the frame, then click two people on it.
      await tester.tap(find.byKey(const Key('tag-frame')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('frame-tagger')), findsOneWidget);
      expect(find.textContaining('0:07.4'), findsOneWidget);
      Future<void> clickAndName(String name, double fx, double fy) async {
        await tester.ensureVisible(find.byKey(const Key('tag-surface')));
        await tester.pumpAndSettle();
        final surface = tester.getRect(find.byKey(const Key('tag-surface')));
        await tester.tapAt(
          surface.topLeft + Offset(surface.width * fx, surface.height * fy),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('annotation-name')), name);
        await tester.tap(find.byKey(const Key('save-name')));
        await tester.pumpAndSettle();
      }

      await clickAndName('Rex', 0.25, 0.5);
      await clickAndName('Ana', 0.75, 0.4);
      await tester.ensureVisible(find.byKey(const Key('done-tagging')));
      await tester.tap(find.byKey(const Key('done-tagging')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, 'Rex'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'Ana'), findsOneWidget);

      final tags = clipEvent(tester).annotations;
      expect(tags.items.map((a) => a.name), ['Rex', 'Ana']);
      final frameId = tags.items.first.frameId!;
      expect(tags.items.every((a) => a.frameId == frameId), isTrue);
      expect(tags.items.first.frameMs, 7400);
      expect(tags.items.first.x, closeTo(0.25, 0.01));
      expect(tags.items.first.y, closeTo(0.5, 0.01));
      await settleStorage(tester);

      // Saved with the event: the frame image, positions and names come back.
      await refresh(tester, cameras: [camera]);
      await showEvents(tester);
      final restored = clipEvent(tester).annotations;
      expect(restored.items.map((a) => (a.name, a.frameId, a.frameMs)), [
        ('Rex', frameId, 7400),
        ('Ana', frameId, 7400),
      ]);
      expect(restored.items.last.x, closeTo(0.75, 0.01));
      expect(restored.frames[frameId]!.jpeg, onePixelPng);
      final eventId = clipEvent(tester).id;
      final record = await run(
        tester,
        storage.open(EventStore.dbName).then((db) async {
          final txn = db.transaction(EventStore.events, idbModeReadOnly);
          final value = await txn
              .objectStore(EventStore.events)
              .getObject(eventId);
          await txn.completed;
          db.close();
          return value as Map;
        }),
      );
      expect((record['annotations'] as List).map((a) => (a as Map)['name']), [
        'Rex',
        'Ana',
      ]);
      expect((record['frames'] as Map).keys, [frameId]);

      // The frame reopens for more tags; removing the last tag drops it.
      await tester.tap(inEvents(find.byKey(const Key('clip-play'))));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(Key('frame-$frameId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('frame-$frameId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('frame-tagger')), findsOneWidget);
      for (final name in ['Rex', 'Ana']) {
        await tester.ensureVisible(find.widgetWithText(InputChip, name));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.widgetWithText(InputChip, name),
            matching: find.byTooltip('Remove'),
          ),
        );
        await tester.pumpAndSettle();
      }
      expect(clipEvent(tester).annotations.isEmpty, isTrue);
      expect(clipEvent(tester).annotations.frames, isEmpty);
    },
  );

  testWidgets('tags: clicking the video tags that frame at the spot', (
    tester,
  ) async {
    ClipPlayerController.debugCaptureOverride = () async => CapturedFrame(
      jpeg: onePixelPng,
      position: const Duration(milliseconds: 3200),
    );
    addTearDown(() => ClipPlayerController.debugCaptureOverride = null);
    final camera = FakeCameraSource('Front door');
    await launch(tester, cameras: [camera]);
    await pressClip(tester);
    camera.pastCompleters.single.complete(past);
    await settleStorage(tester);
    camera.fullCompleters.single.complete(full);
    await settleStorage(tester);

    await tester.tap(inEvents(find.byKey(const Key('clip-play'))));
    await tester.pumpAndSettle();
    final player = tester
        .widget<ClipPlayerView>(find.byType(ClipPlayerView))
        .controller!;

    // A click the name prompt is cancelled for tags nothing: back to video.
    player.pictureTapped(const Offset(0.5, 0.5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('frame-tagger')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('frame-tagger')), findsNothing);
    expect(clipEvent(tester).annotations.isEmpty, isTrue);

    // A named click: the frame stays over the player, tagged there.
    player.pictureTapped(const Offset(0.3, 0.6));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('annotation-name')), 'Rex');
    await tester.tap(find.byKey(const Key('save-name')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('frame-tagger')), findsOneWidget);
    final tagger = tester.getRect(find.byKey(const Key('frame-tagger')));
    final video = tester.getRect(
      find.byType(ClipPlayerView, skipOffstage: false),
    );
    expect(video.contains(tagger.center), isTrue);
    final rex = clipEvent(tester).annotations.items.single;
    expect((rex.name, rex.x, rex.y, rex.frameMs), ('Rex', 0.3, 0.6, 3200));
    expect(clipEvent(tester).annotations.frames.keys, [rex.frameId]);
  });

  testWidgets('the before-only file is deleted once the full clip is saved', (
    tester,
  ) async {
    final camera = FakeCameraSource('Front door');
    await launch(tester, cameras: [camera]);
    await pressClip(tester);

    camera.pastCompleters.single.complete(past);
    await settleStorage(tester);
    final store = await run(tester, EventStore.open(storage));
    final clipId = clipEvent(tester).clip.id;
    expect(await run(tester, store.mediaIds()), ['$clipId-past']);

    camera.fullCompleters.single.complete(full);
    await settleStorage(tester);
    expect(await run(tester, store.mediaIds()), ['$clipId-full']);
    store.close();
  });

  testWidgets('a clip cut short by a refresh keeps its before part', (
    tester,
  ) async {
    final camera = FakeCameraSource('Front door');
    await launch(tester, cameras: [camera]);
    await pressClip(tester);
    camera.pastCompleters.single.complete(past);
    await settleStorage(tester);

    // Reload during the "after" part.
    await refresh(tester, cameras: [camera]);
    await showEvents(tester);

    expect(
      inEvents(
        find.text(
          'Previous 15 s only: the app closed before the next 15 s '
          'were recorded',
        ),
      ),
      findsOneWidget,
    );
    final clip = clipEvent(tester).clip;
    expect(clip.playable, isTrue);
    expect(await run(tester, clip.past!.resolveUrl()), 'restored:blob:past');
  });

  testWidgets('events reference their clips and cameras', (tester) async {
    final camera = FakeCameraSource('Front door', id: 'device-123');
    await launch(tester, cameras: [camera]);
    await pressClip(tester);
    camera.pastCompleters.single.complete(past);
    camera.fullCompleters.single.complete(full);
    await settleStorage(tester);

    final store = await run(tester, EventStore.open(storage));
    final events = await run(tester, store.allEvents());
    final clips = await run(tester, store.allClips());
    final cameras = await run(tester, store.allCameras());
    store.close();

    final clipEventRecord = events.singleWhere(
      (e) => e['type'] == ClipRequested.clipRequestedType,
    );
    final clipRecord = clips.single;
    expect(clipEventRecord['cameraId'], 'device-123');
    expect(clipEventRecord['clipId'], clipRecord['id']);
    expect(clipRecord['eventId'], clipEventRecord['id']);
    expect(clipRecord['cameraId'], 'device-123');
    expect(clipRecord['state'], 'complete');
    // The stored event was updated once the full clip arrived.
    expect(clipEventRecord['clipState'], 'complete');
    expect(cameras.single['id'], 'device-123');
    expect(cameras.single['label'], 'Front door');
  });

  testWidgets('motion settings survive a refresh', (tester) async {
    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    Finder slider(String key) => find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(Slider),
    );
    await tester.drag(slider('motion-threshold-slider'), const Offset(1000, 0));
    await tester.drag(slider('motion-cooldown-slider'), const Offset(-1000, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('motion-switch')));
    await tester.pumpAndSettle();
    await settleStorage(tester);

    await refresh(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('50 % of the picture'), findsOneWidget);
    expect(find.text('1 min'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('motion-switch')))
          .value,
      isFalse,
    );
  });

  testWidgets('brightness survives a refresh', (tester) async {
    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.descendant(
        of: find.byKey(const Key('brightness-slider')),
        matching: find.byType(Slider),
      ),
      const Offset(-1000, 0),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);

    await refresh(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('-2.0 EV'), findsOneWidget);
  });

  testWidgets('settings saved before the config object still load', (
    tester,
  ) async {
    // What older versions stored: one flat "clip" record.
    final store = await run(tester, EventStore.open(storage));
    await run(
      tester,
      store.putSettings('clip', {
        'beforeMs': 30000,
        'afterMs': 10000,
        'brightnessEv': -0.5,
        'motionEnabled': false,
        'motionThreshold': 22,
        'motionCooldownMs': 720000,
      }),
    );
    store.close();

    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Clips play 40 s in total'), findsOneWidget);
    expect(find.text('-0.5 EV'), findsOneWidget);
    expect(find.text('22 % of the picture'), findsOneWidget);
    expect(find.text('12 min'), findsOneWidget);
  });

  testWidgets(
    'the motion cooldown survives a restart, with its exact countdown',
    (tester) async {
      Future<void> frames(FakeCameraSource camera, List<dynamic> list) async {
        for (final f in list) {
          clock = clock.add(const Duration(milliseconds: 200));
          camera.motion.add(f);
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 600));
      }

      var step = 0;
      List<dynamic> movement() => [
        for (var i = 0; i < 4; i++)
          frame(x: (step++ % 2) * 30 + 5, y: 10, size: 24),
      ];
      const media = ClipMedia(
        url: 'blob:m',
        start: Duration.zero,
        end: Duration(seconds: 15),
      );

      var camera = FakeCameraSource('Main', immediatePast: media);
      await launch(tester, cameras: [camera]);
      await frames(camera, List.filled(20, frame())); // warm-up
      await frames(camera, movement());
      final triggeredAt = clock.subtract(const Duration(milliseconds: 200));
      expect(camera.fullCompleters, hasLength(1), reason: 'motion clip taken');
      camera.fullCompleters.single.complete(media);
      await settleStorage(tester);

      // Two minutes later, the app restarts.
      clock = triggeredAt.add(const Duration(minutes: 2));
      camera = FakeCameraSource('Main', immediatePast: media);
      await refresh(tester, cameras: [camera]);
      await tester.pump(const Duration(milliseconds: 600));

      // The pill shows exactly what's left of the 5-minute cooldown.
      expect(find.text('3:00'), findsOneWidget);

      // Motion stays blocked until the cooldown ends…
      await frames(camera, List.filled(20, frame()));
      await frames(camera, movement());
      expect(camera.fullCompleters, isEmpty);

      // …and clips again once it has.
      clock = triggeredAt.add(const Duration(minutes: 5));
      await frames(camera, movement());
      expect(camera.fullCompleters, hasLength(1));
      await settleStorage(tester);
    },
  );

  testWidgets('clip settings survive a refresh', (tester) async {
    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.descendant(
        of: find.byKey(const Key('clip-before-slider')),
        matching: find.byType(Slider),
      ),
      const Offset(1000, 0),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);

    await refresh(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Clips play 75 s in total'), findsOneWidget);
    // Brightness is saved too (still the default here).
    expect(find.text('+1.0 EV'), findsOneWidget);
  });
}
