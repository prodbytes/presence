/// Recordings' Blob URLs are freed in a real browser once nothing uses
/// them: `flutter test --platform chrome test/chrome/`.
@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/recognition/frames.dart';

import 'frames_test.dart' show recordCanvas;

/// Whether [url] still serves its bytes.
Future<bool> readable(String url) async {
  try {
    await web.window.fetch(url.toJS).toDart;
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a live recording is revoked once saved and no sampler uses it',
    () async {
      final url = await recordCanvas(2);
      final media = ClipMedia(
        url: url,
        start: Duration.zero,
        end: const Duration(seconds: 2),
      );
      expect(MediaUrls.instance.isLive(url), isTrue, reason: 'tracked on web');
      final sampler = ClipFrameSampler();
      var frames = 0;
      await for (final _ in sampler.sample(
        media,
        every: const Duration(milliseconds: 500),
      )) {
        if (frames++ == 0) {
          // Saved while sampled: still readable until the sampler is done.
          media.persisted(() async => url);
          expect(await readable(url), isTrue);
        }
      }
      expect(frames, greaterThan(0));
      expect(await readable(url), isFalse, reason: 'revoked');
      expect(MediaUrls.instance.isLive(url), isFalse);
    },
  );
}
