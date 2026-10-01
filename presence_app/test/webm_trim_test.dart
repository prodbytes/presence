import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/cameras/webm_trim.dart';

/// A WebM laid out like Chrome's MediaRecorder writes it: unknown-size
/// segment and clusters, a cluster per video keyframe (and one more in
/// between, as Chrome starts one when timecodes would overflow), video
/// track 1 every 100 ms, audio track 2 every 60 ms.
Uint8List recording({
  Duration length = const Duration(seconds: 20),
  Duration keyframeEvery = const Duration(seconds: 5),
}) {
  List<int> element(int id, List<int> data, {bool unknown = false}) {
    final idBytes = <int>[];
    for (var v = id; v > 0; v >>= 8) {
      idBytes.insert(0, v & 0xFF);
    }
    // Known sizes in one byte: these elements stay under 127 bytes.
    assert(unknown || data.length < 127);
    final size = unknown
        ? [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        : [0x80 | data.length];
    return [...idBytes, ...size, ...data];
  }

  List<int> uint(int v, int bytes) => [
    for (var i = bytes - 1; i >= 0; i--) (v >> (8 * i)) & 0xFF,
  ];

  final header = element(0x1A45DFA3, [
    ...element(0x4282, 'webm'.codeUnits), // DocType
  ]);
  final info = element(0x1549A966, [
    ...element(0x2AD7B1, uint(1000000, 3)), // TimecodeScale: ms
    ...element(0x4D80, 'Chrome'.codeUnits), // MuxingApp
  ]);
  final tracks = element(0x1654AE6B, [
    ...element(0xAE, [
      ...element(0xD7, [1]),
      ...element(0x83, [1]),
    ]),
    ...element(0xAE, [
      ...element(0xD7, [2]),
      ...element(0x83, [2]),
    ]),
  ]);

  // Every frame, in time order.
  final frames = <(int ms, int track, bool key)>[];
  for (var ms = 0; ms < length.inMilliseconds; ms += 100) {
    frames.add((ms, 1, ms % keyframeEvery.inMilliseconds == 0));
  }
  for (var ms = 0; ms < length.inMilliseconds; ms += 60) {
    frames.add((ms, 2, true));
  }
  frames.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);

  final clusters = <int>[];
  var body = <int>[];
  int? clusterMs;
  void flush() {
    if (clusterMs == null) return;
    clusters.addAll(
      element(0x1F43B675, [
        ...element(0xE7, uint(clusterMs, 4)),
        ...body,
      ], unknown: true),
    );
    body = [];
  }

  for (final (ms, track, key) in frames) {
    final isVideoKey = track == 1 && key;
    // Also a cluster break that isn't at a keyframe, at 12.5 s.
    if (clusterMs == null || isVideoKey || (ms >= 12500 && clusterMs < 12500)) {
      flush();
      clusterMs = ms;
    }
    final rel = ms - clusterMs;
    body.addAll(
      element(0xA3, [
        0x80 | track,
        (rel >> 8) & 0xFF,
        rel & 0xFF,
        key ? 0x80 : 0x00,
        // The frame "data": its own time, to check nothing got mixed up.
        ...uint(ms, 4),
      ]),
    );
  }
  flush();

  return Uint8List.fromList([
    ...header,
    ...element(0x18538067, [...info, ...tracks, ...clusters], unknown: true),
  ]);
}

const s = Duration(seconds: 1);

void main() {
  test('reads a recording', () {
    final blocks = webmBlocks(recording())!;
    expect(blocks.where((b) => b.track == 1), hasLength(200));
    expect(blocks.where((b) => b.track == 1 && b.keyframe), hasLength(4));
    expect(blocks.last.time, const Duration(milliseconds: 19980));
  });

  test('cuts from the keyframe before the window to its end', () {
    final cut = cutWebm(recording(), s * 7, s * 12)!;
    // The keyframe at 5 s is the new start.
    expect(cut.start, s * 2);
    expect(cut.end, s * 7);

    final blocks = webmBlocks(cut.bytes)!;
    expect(blocks.first.time, Duration.zero);
    expect(blocks.first.track, 1);
    expect(blocks.first.keyframe, isTrue);
    expect(blocks.last.time, lessThanOrEqualTo(s * 7));
    // Every video frame from 5 s to 12 s, once each, in order.
    final video = blocks.where((b) => b.track == 1).toList();
    expect(video, hasLength(71));
    expect(
      [for (final b in video) b.time.inMilliseconds],
      [for (var ms = 0; ms <= 7000; ms += 100) ms],
    );
    expect(webmDuration(cut.bytes), s * 7);
  });

  test('a window across the non-keyframe cluster break keeps timing', () {
    final cut = cutWebm(recording(), s * 11, s * 14)!;
    expect(cut.start, s * 1); // From the keyframe at 10 s.
    final video = webmBlocks(cut.bytes)!.where((b) => b.track == 1).toList();
    expect(video.first.keyframe, isTrue);
    expect(video.last.time, s * 4);
    expect(video.where((b) => b.keyframe), hasLength(1));
  });

  test('a window from the start keeps the start', () {
    final cut = cutWebm(recording(), Duration.zero, s * 3)!;
    expect(cut.start, Duration.zero);
    expect(cut.end, s * 3);
    expect(webmBlocks(cut.bytes)!.last.time, lessThanOrEqualTo(s * 3));
  });

  test('a cut file can be cut again', () {
    final once = cutWebm(recording(), s * 6, s * 18)!;
    final twice = cutWebm(once.bytes, once.start, once.end)!;
    expect(twice.start, once.start);
    expect(webmBlocks(twice.bytes)!.length, webmBlocks(once.bytes)!.length);
  });

  test("files it doesn't understand are left alone", () {
    expect(cutWebm(Uint8List.fromList([1, 2, 3]), s, s * 2), isNull);
    expect(cutWebm(Uint8List(0), s, s * 2), isNull);
  });
}
