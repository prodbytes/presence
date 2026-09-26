import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
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
    this.facing = CameraFacing.back,
    String? id,
  }) : id = id ?? 'cam-$label';

  final CameraFacing facing;

  CameraDevice get device => CameraDevice(id: id, label: label, facing: facing);

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

  /// Motion frames the test pushes in.
  final StreamController<Uint8List> motion = StreamController.broadcast();

  @override
  Stream<Uint8List> get motionFrames => motion.stream;

  final List<double> brightness = [];

  @override
  Future<void> setBrightness(double ev) async => brightness.add(ev);

  @override
  Future<void> dispose() async => disposed = true;
}

/// Cameras that open instantly as the given fakes, in order.
class FakeCameraBackend implements CameraBackend {
  FakeCameraBackend(this.cameras, {this.listError, this.openError});

  final List<FakeCameraSource> cameras;

  /// Thrown by [listCameras] while set.
  Object? listError;

  /// Thrown by [open] while set.
  Object? openError;

  int lists = 0;
  final List<String> opened = [];

  @override
  Future<List<CameraDevice>> listCameras() async {
    lists++;
    if (listError case final e?) throw e;
    return [for (final c in cameras) c.device];
  }

  @override
  Future<CameraSource> open(
    CameraDevice device,
    Duration Function() preRoll,
  ) async {
    opened.add(device.id);
    if (openError case final e?) throw e;
    return cameras.firstWhere((c) => c.id == device.id);
  }
}

FakeCameraBackend openFakes(List<FakeCameraSource> cameras) =>
    FakeCameraBackend(cameras);

FakeCameraBackend get noCameras => FakeCameraBackend([]);

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

/// Opens the Events tab (a no-op if it's already showing).
Future<void> showEvents(WidgetTester tester) async {
  if (find.byKey(const Key('events-page')).evaluate().isNotEmpty) return;
  await tester.tap(find.byTooltip('Events'));
  await tester.pumpAndSettle();
}

/// Goes to the Camera tab, presses Clip, waits for the events to publish
/// (up to CameraRig.pastWait), then shows the Events tab.
Future<void> clipAndShowEvents(WidgetTester tester) async {
  if (find.byTooltip('Clip').evaluate().isEmpty) {
    await tester.tap(find.byTooltip('Camera'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.byTooltip('Clip'));
  await tester.pump(CameraRig.pastWait);
  await tester.pumpAndSettle();
  await settleStorage(tester);
  await showEvents(tester);
}

/// Sign-in without Google: signIn() signs in as [account].
class FakeAuthService extends AuthService {
  FakeAuthService({
    this.account = const AuthUser(
      id: '1',
      email: 'ana@example.com',
      name: 'Ana',
    ),
    bool signedIn = false,
  }) : _user = signedIn ? account : null;

  /// Already signed in at launch (a restored session).
  FakeAuthService.signedIn() : this(signedIn: true);

  final AuthUser account;
  AuthUser? _user;

  @override
  bool get checking => false;

  @override
  AuthUser? get user => _user;
  @override
  String? get idToken => _user == null ? null : 'id-token-${_user!.id}';
  @override
  bool get available => true;
  @override
  String? get unavailableReason => null;
  @override
  String? get error => null;
  @override
  Future<void> init() async {}
  @override
  Future<void> signIn() async {
    _user = account;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    _user = null;
    notifyListeners();
  }

  @override
  Widget? buildSignInButton() => null;
}

/// Records uploads; can be told to fail.
class FakeCloudBackend implements CloudBackend {
  final uploads = <String, ({Uint8List bytes, String contentType})>{};
  final tokens = <String>[];
  int resets = 0;

  /// Thrown by the next connect(), once.
  Object? failConnect;

  /// Thrown by the next put(), once.
  Object? failPut;

  @override
  Future<CloudSession> connect(String idToken) async {
    tokens.add(idToken);
    if (failConnect case final e?) {
      failConnect = null;
      throw e;
    }
    return FakeCloudSession(this);
  }

  @override
  void reset() => resets++;
}

class FakeCloudSession implements CloudSession {
  FakeCloudSession(this.backend);

  final FakeCloudBackend backend;

  @override
  String get prefix => 'us-east-1:identity';

  @override
  Future<void> put(String key, Uint8List bytes, String contentType) async {
    if (backend.failPut case final e?) {
      backend.failPut = null;
      throw e;
    }
    backend.uploads['$prefix/$key'] = (bytes: bytes, contentType: contentType);
  }
}
