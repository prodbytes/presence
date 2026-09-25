import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/storage/media_store.dart';

/// A valid 1×1 PNG, so `Image.memory` can decode fake thumbnails.
final Uint8List onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// A camera whose clip recordings the test completes by hand.
class FakeCameraSource implements CameraSource {
  FakeCameraSource(
    this.label, {
    this.supportsVideo = true,
    this.immediatePast,
    String? id,
  }) : id = id ?? 'cam-$label';

  /// When set, the "before" recording is ready as soon as a clip is
  /// requested, like the real recorder; otherwise the test completes it.
  final ClipMedia? immediatePast;

  @override
  final String id;

  @override
  final String label;

  @override
  final bool supportsVideo;

  final List<({Duration before, Duration after})> requests = [];
  final List<Completer<ClipMedia?>> pastCompleters = [];
  final List<Completer<ClipMedia?>> fullCompleters = [];
  bool disposed = false;

  @override
  Widget buildPreview(BuildContext context) =>
      SizedBox.expand(key: Key('preview-$label'));

  @override
  Future<Uint8List?> captureFrame() async => onePixelPng;

  @override
  ClipCapture requestClip({required Duration before, required Duration after}) {
    requests.add((before: before, after: after));
    final past = Completer<ClipMedia?>();
    final full = Completer<ClipMedia?>();
    if (immediatePast != null) past.complete(immediatePast);
    pastCompleters.add(past);
    fullCompleters.add(full);
    return ClipCapture(past: past.future, full: full.future);
  }

  @override
  void dispose() => disposed = true;
}

CameraOpener openFakes(List<CameraSource> sources) =>
    (_) async => sources;

Future<List<CameraSource>> noCameras(Duration Function() _) async => [];

/// The in-memory storage backend completes its work on timers, which widget
/// tests only run when fake time advances.
Future<void> settleStorage(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 1));

/// Stands in for the browser: "recordings" at a URL are the URL's bytes,
/// and restored recordings get a recognizable URL.
Future<Uint8List> fakeReadBytes(String url) async =>
    Uint8List.fromList(url.codeUnits);

String fakeCreateUrl(Uint8List bytes, String mimeType) =>
    'restored:${String.fromCharCodes(bytes)}';

const fakeMediaIo = MediaIo(readBytes: fakeReadBytes, createUrl: fakeCreateUrl);
