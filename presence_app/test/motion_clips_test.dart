import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/config.dart';

import 'fakes.dart';
import 'motion_test.dart' show frame;

void main() {
  // CameraRig listens to app lifecycle, which needs a binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  const media = ClipMedia(
    url: 'blob:fake',
    start: Duration.zero,
    end: Duration(seconds: 15),
  );

  late DateTime now;
  late ConfigController config;
  late AppEventBus bus;
  late List<ClipRequested> clips;
  late FakeCameraSource camera;
  late CameraRig rig;

  setUp(() async {
    now = DateTime(2026, 9, 25, 12);
    config = ConfigController();
    bus = AppEventBus();
    clips = [];
    bus.stream.listen((e) {
      if (e is ClipRequested) clips.add(e);
    });
    camera = FakeCameraSource('Main', immediatePast: media);
    rig = CameraRig(
      backend: openFakes([camera]),
      config: config,
      bus: bus,
      now: () => now,
    );
    await rig.load();
  });

  tearDown(() {
    rig.dispose();
    bus.close();
  });

  /// Sends frames spaced like the real 5 per second sampling.
  Future<void> send(List<dynamic> frames) async {
    for (final f in frames) {
      now = now.add(const Duration(milliseconds: 200));
      camera.motion.add(f);
      await Future<void>.delayed(Duration.zero);
    }
    // Let any clip request finish publishing.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  /// Still frames through the warm-up, so scores start counting.
  Future<void> settle() => send(List.filled(20, frame()));

  /// A square jumping between two spots: 19 % of the picture changes on the
  /// first frame, then 37.5 % (it leaves one spot and covers the other).
  List<dynamic> movement(int n) => [
    for (var i = 0; i < n; i++) frame(x: (i % 2) * 30, y: 10, size: 24),
  ];

  test('enough motion takes a clip, like pressing Clip', () async {
    await settle();
    expect(clips, isEmpty);

    await send(movement(4));

    expect(clips, hasLength(1));
    expect(clips.single.trigger, ClipTrigger.motion);
    expect(clips.single.title, 'Motion detected');
    // Same clip as a manual one: this camera, the configured window.
    expect(camera.requests.single.before, config.clip.before);
    expect(camera.requests.single.after, config.clip.after);
    expect(clips.single.clip.playable, isTrue);
  });

  test('motion below the threshold does nothing', () async {
    config.update((c) => c.copyWith(motion: c.motion.copyWith(threshold: 40)));
    await settle();
    await send(movement(5)); // at most 37.5 % < 40 %
    expect(clips, isEmpty);
  });

  test('a single noisy frame does not trigger', () async {
    await settle();
    await send([frame(x: 10, y: 10, size: 24), frame(), frame(), frame()]);
    expect(clips, isEmpty);
  });

  test('at most one automatic clip per cooldown', () async {
    await settle();
    await send(movement(4));
    expect(clips, hasLength(1));

    // More motion within 5 minutes: no new clip.
    now = now.add(const Duration(minutes: 4));
    await send(movement(6));
    expect(clips, hasLength(1));

    // After the cooldown: clips again.
    now = now.add(const Duration(minutes: 1, seconds: 1));
    await send(movement(4));
    expect(clips, hasLength(2));
  });

  test('the cooldown is configurable', () async {
    config.update(
      (c) => c.copyWith(
        motion: c.motion.copyWith(cooldown: const Duration(minutes: 1)),
      ),
    );
    await settle();
    await send(movement(4));
    now = now.add(const Duration(minutes: 1, seconds: 1));
    await send(movement(4));
    expect(clips, hasLength(2));
  });

  test('manual clips are not limited by the cooldown', () async {
    await settle();
    await send(movement(4));
    await rig.requestClips(bus);
    await Future<void>.delayed(Duration.zero);
    expect(clips.map((c) => c.trigger), [
      ClipTrigger.motion,
      ClipTrigger.manual,
    ]);
  });

  test('turned off, motion never clips', () async {
    config.update((c) => c.copyWith(motion: c.motion.copyWith(enabled: false)));
    await settle();
    await send(movement(10));
    expect(clips, isEmpty);
  });

  test('the live motion level is published', () async {
    await settle();
    expect(rig.motionLevel.value, 0);
    await send(movement(1));
    expect(rig.motionLevel.value, closeTo(18.75, 1));
  });
}
