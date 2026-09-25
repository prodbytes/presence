import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';

import 'fakes.dart';

void main() {
  late IdbFactory storage;

  setUp(() => storage = newIdbFactoryMemory());

  Future<void> launch(
    WidgetTester tester, {
    List<CameraSource> cameras = const [],
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        // A new key forces a fresh app, like a page reload.
        key: UniqueKey(),
        openCameras: openFakes(cameras),
        storage: storage,
        mediaIo: fakeMediaIo,
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
    await tester.pumpAndSettle();
  }

  /// Closes the app and opens it again on the same storage.
  Future<void> refresh(
    WidgetTester tester, {
    List<CameraSource> cameras = const [],
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
      find.descendant(of: find.byKey(const Key('events-panel')), matching: f);

  Future<void> pressClip(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Clip'));
    // Events wait (up to CameraRig.pastWait) for the before part.
    await tester.pump(CameraRig.pastWait);
    await tester.pumpAndSettle();
    await settleStorage(tester);
  }

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
  });
}
