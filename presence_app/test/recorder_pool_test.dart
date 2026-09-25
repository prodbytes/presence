import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/cameras/recorder_pool.dart';

class FakeRecorder implements PoolRecorder {
  FakeRecorder(this.id, this.startedAt);

  final int id;
  @override
  final DateTime startedAt;
  @override
  String get mimeType => 'video/webm';
  bool finished = false;
  bool discarded = false;

  @override
  Future<String> finish() async {
    finished = true;
    return 'rec-$id';
  }

  @override
  void discard() => discarded = true;
}

void main() {
  const preRoll = Duration(seconds: 15);
  const after = Duration(seconds: 15);
  final t0 = DateTime(2026, 9, 25, 12);

  late DateTime now;
  late List<FakeRecorder> recorders;
  late RecorderPool pool;

  setUp(() {
    now = t0;
    recorders = [];
    pool = RecorderPool(
      startRecorder: () {
        final r = FakeRecorder(recorders.length, now);
        recorders.add(r);
        return r;
      },
      preRoll: () => preRoll,
      now: () => now,
    );
  });

  /// Advances the clock second by second, ticking like the real timer.
  Future<void> runFor(Duration d) async {
    for (var i = 0; i < d.inSeconds; i++) {
      now = now.add(const Duration(seconds: 1));
      pool.tick();
    }
    await Future<void>.delayed(Duration.zero);
  }

  FakeRecorder recorderFor(String url) =>
      recorders[int.parse(url.substring('rec-'.length))];

  test('keeps a bounded set of overlapping recorders', () async {
    pool.tick();
    await runFor(const Duration(minutes: 3));

    expect(pool.activeCount, inInclusiveRange(4, 5));
    for (final r in recorders.where((r) => r.discarded)) {
      expect(r.finished, isFalse);
    }
    // Old recorders are thrown away once they're past 2 × preRoll.
    expect(recorders.first.discarded, isTrue);
  });

  test('every press gets the exact before and after windows', () async {
    pool.tick();
    await runFor(const Duration(seconds: 40)); // Warm up past 2 × preRoll.

    // Try a press at every phase of the recorder rotation.
    for (var phase = 0; phase < 8; phase++) {
      await runFor(const Duration(seconds: 1));
      final pressedAt = now;
      final capture = pool.requestClip(before: preRoll, after: after);

      final past = (await capture.past)!;
      expect(past.length, preRoll, reason: 'phase $phase');
      final pastRecorder = recorderFor(past.liveUrl!);
      expect(
        pastRecorder.startedAt.add(past.start),
        pressedAt.subtract(preRoll),
        reason: 'phase $phase: before-window starts 15 s before the press',
      );

      var fullDone = false;
      ClipMedia? full;
      capture.full.then((m) {
        full = m;
        fullDone = true;
      });
      await runFor(const Duration(seconds: 14));
      expect(fullDone, isFalse, reason: 'full clip waits for the after part');
      await runFor(const Duration(seconds: 1));
      expect(fullDone, isTrue, reason: 'phase $phase');

      expect(full!.length, preRoll + after);
      final fullRecorder = recorderFor(full!.liveUrl!);
      expect(fullRecorder, isNot(same(pastRecorder)));
      expect(
        fullRecorder.startedAt.add(full!.start),
        pressedAt.subtract(preRoll),
      );
      expect(fullRecorder.startedAt.add(full!.end), pressedAt.add(after));
    }
  });

  test('a press right after startup uses what has been recorded', () async {
    pool.tick();
    await runFor(const Duration(seconds: 5));

    final capture = pool.requestClip(before: preRoll, after: after);
    await runFor(const Duration(seconds: 15));

    final full = (await capture.full)!;
    // Only 5 s of history existed: the clip starts at the recording start.
    expect(full.start, Duration.zero);
    expect(full.end, const Duration(seconds: 20));
  });

  test('presses close together share the held recorder', () async {
    pool.tick();
    await runFor(const Duration(seconds: 40));

    final first = pool.requestClip(before: preRoll, after: after);
    await runFor(const Duration(seconds: 3));
    final second = pool.requestClip(before: preRoll, after: after);
    await runFor(const Duration(seconds: 20));

    final a = (await first.full)!;
    final b = (await second.full)!;
    expect(a.liveUrl, b.liveUrl);
    expect(a.length, preRoll + after);
    expect(b.length, preRoll + after);
    expect(b.start - a.start, const Duration(seconds: 3));
  });

  test('close finishes pending clips with what was recorded', () async {
    pool.tick();
    await runFor(const Duration(seconds: 40));

    final capture = pool.requestClip(before: preRoll, after: after);
    await runFor(const Duration(seconds: 5));
    pool.close();

    final full = await capture.full;
    expect(full, isNotNull);
    expect(
      recorders.where((r) => !r.finished).every((r) => r.discarded),
      isTrue,
    );
  });

  test('no recorders yet means no clip', () async {
    final capture = pool.requestClip(before: preRoll, after: after);
    expect(await capture.past, isNull);
    expect(await capture.full, isNull);
  });
}
