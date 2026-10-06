import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  FakeCameraSource back() => FakeCameraSource('Main');
  FakeCameraSource wide() => FakeCameraSource('Wide');
  FakeCameraSource front() =>
      FakeCameraSource('Selfie', facing: CameraFacing.front);

  Future<CameraRig> start(
    List<FakeCameraSource> cameras,
    ConfigController config,
  ) async {
    final rig = CameraRig(backend: openFakes(cameras), config: config);
    addTearDown(rig.dispose);
    await rig.load();
    return rig;
  }

  group('the camera picked with Flip', () {
    test('is kept in the settings and reopened at the next launch', () async {
      final config = ConfigController();
      final first = await start([back(), wide(), front()], config);
      expect(first.current?.id, 'cam-Main');
      await first.flip();
      expect(first.current?.id, 'cam-Selfie');
      expect(
        config.camera.chosen,
        const ChosenCamera(id: 'cam-Selfie', label: 'Selfie', facing: 'front'),
      );

      // A restart: a new rig with the same settings.
      final restored = ConfigController(
        PresenceConfig.fromJson(config.config.toJson()),
      );
      final again = await start([back(), wide(), front()], restored);
      expect(again.current?.id, 'cam-Selfie');
      expect(again.active?.id, 'cam-Selfie');
    });

    test('flipping back remembers the back camera', () async {
      final config = ConfigController();
      final rig = await start([back(), front()], config);
      await rig.flip();
      await rig.flip();
      expect(rig.current?.id, 'cam-Main');
      expect(config.camera.chosen?.id, 'cam-Main');
    });

    test('gone: the default camera opens', () async {
      final config = ConfigController(
        const PresenceConfig(
          camera: CameraConfig(
            chosen: ChosenCamera(
              id: 'usb-cam',
              label: 'USB',
              facing: 'unknown',
            ),
          ),
        ),
      );
      final rig = await start([back(), front()], config);
      expect(rig.current?.id, 'cam-Main');
      expect(rig.active?.id, 'cam-Main');
    });

    test('found by label and facing when its ID changed', () {
      final devices = [
        const CameraDevice(id: 'a', label: 'Main', facing: CameraFacing.back),
        const CameraDevice(id: 'b', label: 'Wide', facing: CameraFacing.back),
      ];
      expect(
        CameraRig.startCamera(
          devices,
          const ChosenCamera(id: 'old', label: 'Wide', facing: 'back'),
        )?.id,
        'b',
      );
    });

    test('else another camera facing the same way', () {
      final devices = [
        const CameraDevice(id: 'a', label: 'Main', facing: CameraFacing.back),
        const CameraDevice(
          id: 'c',
          label: 'Front 2',
          facing: CameraFacing.front,
        ),
      ];
      expect(
        CameraRig.startCamera(
          devices,
          const ChosenCamera(id: 'old', label: 'Front', facing: 'front'),
        )?.id,
        'c',
      );
    });

    test('none remembered: the first back camera, else the first', () {
      const front = CameraDevice(
        id: 'f',
        label: 'F',
        facing: CameraFacing.front,
      );
      const rear = CameraDevice(id: 'r', label: 'R', facing: CameraFacing.back);
      expect(CameraRig.startCamera([front, rear], null), rear);
      expect(CameraRig.startCamera([front], null), front);
      expect(CameraRig.startCamera(const [], null), isNull);
    });

    test('restored after the cameras opened: switches to it', () async {
      final config = ConfigController();
      final rig = await start([back(), front()], config);
      expect(rig.active?.id, 'cam-Main');
      config.update(
        (c) => c.copyWith(
          camera: c.camera.copyWith(
            chosen: const ChosenCamera(
              id: 'cam-Selfie',
              label: 'Selfie',
              facing: 'front',
            ),
          ),
        ),
      );
      await pumpEventQueue();
      expect(rig.active?.id, 'cam-Selfie');
    });

    test('survives the settings JSON; damaged or missing reads as none', () {
      const camera = CameraConfig(
        chosen: ChosenCamera(id: 'x', label: 'X', facing: 'front'),
      );
      expect(CameraConfig.fromJson(camera.toJson()), camera);
      expect(const CameraConfig().toJson().containsKey('chosen'), isFalse);
      expect(CameraConfig.fromJson({'brightnessEv': 1}).chosen, isNull);
      expect(CameraConfig.fromJson({'chosen': 'x'}).chosen, isNull);
      expect(
        CameraConfig.fromJson({
          'chosen': {'label': 'no id'},
        }).chosen,
        isNull,
      );
    });
  });

  testWidgets('the app reopens the flipped camera after a restart', (
    tester,
  ) async {
    final storage = newIdbFactoryMemory();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Future<FakeCameraBackend> launch() async {
      final backend = openFakes([back(), front()]);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          key: UniqueKey(),
          cameras: backend,
          storage: storage,
          mediaIo: fakeMediaIo,
          auth: FakeAuthService.signedIn(),
          rolesClient: FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);
      await tester.pumpAndSettle();
      return backend;
    }

    final first = await launch();
    expect(first.opened, ['cam-Main']);
    await tester.tap(find.byTooltip('Flip camera'));
    await tester.pumpAndSettle();
    await settleStorage(tester);
    expect(find.byKey(const Key('preview-Selfie')), findsOneWidget);

    // Closed and opened again on the same storage.
    await tester.pumpWidget(const SizedBox());
    await settleStorage(tester);
    final second = await launch();
    // Straight to it: the default camera isn't opened first.
    expect(second.opened, ['cam-Selfie']);
    expect(find.byKey(const Key('preview-Selfie')), findsOneWidget);
  });
}
