import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/config.dart';

import 'fakes.dart';

void main() {
  group('a camera the platform takes away', () {
    testWidgets('is closed and reopened, retrying until it opens', (
      tester,
    ) async {
      final back = FakeCameraSource('Main');
      final backend = openFakes([back]);
      final rig = CameraRig(backend: backend, config: ConfigController());
      await rig.load();
      expect(rig.active, back);
      expect(backend.opened, [back.id]);

      // Android takes it (e.g. with the screen off), and won't give it back
      // at first.
      backend.openError = const CameraUnavailable('Camera is disabled');
      back.lostCompleter.complete('Camera disconnected');
      await tester.pump();
      expect(back.disposed, isTrue);
      expect(rig.active, isNull);
      expect(rig.error, isA<CameraUnavailable>());
      expect(backend.opened, hasLength(1));

      // Retried after the delay, and again after a failure.
      await tester.pump(CameraRig.lostRetryDelay);
      expect(backend.opened, hasLength(2));
      expect(rig.active, isNull);
      backend.openError = null;
      await tester.pump(CameraRig.lostRetryDelay);
      expect(backend.opened, hasLength(3));
      expect(rig.active, back);
      expect(rig.error, isNull);

      // Back: no more retries.
      await tester.pump(CameraRig.lostRetryDelay * 3);
      expect(backend.opened, hasLength(3));
      rig.dispose();
    });

    testWidgets('a camera already closed is not reopened', (tester) async {
      final back = FakeCameraSource('Main');
      final backend = openFakes([back]);
      final rig = CameraRig(backend: backend, config: ConfigController());
      await rig.load();
      rig.dispose();
      back.lostCompleter.complete('Camera disconnected');
      await tester.pump(CameraRig.lostRetryDelay * 2);
      expect(backend.opened, hasLength(1));
    });
  });
}
