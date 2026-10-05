import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/membership_client.dart';
import 'package:presence_app/auth/profile_client.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/location/device_location.dart';
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
  await tester.tap(find.byTooltip('Monitoring'));
  await tester.pumpAndSettle();
}

/// Turns on the Monitoring tab's "Show system events" chip (off by default
/// outside DEV), so plain events such as "Application started" show.
Future<void> revealSystemEvents(WidgetTester tester) async {
  final chip = find.byKey(const Key('show-system-events'));
  if (tester.widget<FilterChip>(chip).selected) return;
  await tester.tap(chip);
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
  int _refreshes = 0;

  @override
  bool get checking => false;

  @override
  AuthUser? get user => _user;
  @override
  String? get idToken => _user == null
      ? null
      : 'id-token-${_user!.id}${_refreshes == 0 ? '' : '-r$_refreshes'}';

  /// A silent sign-in that renews the ID token for the same user.
  void refreshToken() {
    _refreshes++;
    notifyListeners();
  }

  /// A change that leaves the user and token as they were.
  void notify() => notifyListeners();
  @override
  bool get available => true;
  @override
  String? get unavailableReason => null;
  @override
  String? get error => _error;
  String? _error;

  /// A sign-in that fails with [error].
  void fail(String error) {
    _error = error;
    notifyListeners();
  }

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
  final downloads = <String>[];

  /// The prefix of each listing, in order ('' is the whole folder).
  final listings = <String>[];
  int resets = 0;

  /// The folder sessions use (the profile's identity); a link changes it.
  String prefix = 'us-east-1:identity';

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
  late final String prefix = backend.prefix;

  @override
  Future<void> put(String key, Uint8List bytes, String contentType) async {
    if (backend.failPut case final e?) {
      backend.failPut = null;
      throw e;
    }
    backend.uploads['$prefix/$key'] = (bytes: bytes, contentType: contentType);
  }

  @override
  Future<List<String>> list([String under = '']) async {
    backend.listings.add(under);
    return [
      for (final key in backend.uploads.keys)
        if (key.startsWith('$prefix/$under')) key.substring(prefix.length + 1),
    ];
  }

  @override
  Future<Uint8List> get(String key) async {
    backend.downloads.add(key);
    final object = backend.uploads['$prefix/$key'];
    if (object == null) throw StateError('No $key');
    return object.bytes;
  }
}

/// The auth API without HTTP: answers [roles] (changeable), or throws
/// [error]. Records the tokens it was asked about.
class FakeRolesClient implements RolesClient {
  FakeRolesClient([this.roles = const [userRole]]);

  /// No roles: signed-in users only see their account and sign-up.
  FakeRolesClient.none() : this(const []);

  List<String> roles;

  /// The profile ID `GET /api/auth` answers with.
  String? profile = 'automatic_paranoid_axolotl';
  Object? error;
  final tokens = <String>[];

  /// What `GET /api/auth/anonymous` says; RBAC by default.
  ExecutionMode mode = ExecutionMode.rbac;

  /// What `GET /api/auth/anonymous` says is set.
  ApiSettings settings = (oidc: null, aws: null);

  /// Makes the start check fail (the API is unreachable).
  Object? anonymousError;
  int anonymousCalls = 0;

  @override
  Future<UserAccess> fetch(String idToken) async {
    tokens.add(idToken);
    if (error case final e?) throw e;
    return (roles: roles, profile: profile);
  }

  @override
  Future<AnonymousAccess> anonymous() async {
    anonymousCalls++;
    if (anonymousError case final e?) throw e;
    return (
      mode: mode,
      roles: mode == ExecutionMode.dev
          ? const [anonymousRole, userRole, adminRole, rootRole]
          : const [anonymousRole],
      settings: settings,
    );
  }
}

/// Membership requests kept in memory; [granted] records the grants.
class FakeMembershipClient implements MembershipClient {
  final requests = <MembershipRequest>[];
  final sent = <String>[];
  final granted = <String>[];
  Object? error;

  @override
  Future<void> request(String idToken, String message) async {
    if (error case final e?) throw e;
    sent.add(message);
  }

  @override
  Future<List<MembershipRequest>> list(String idToken) async {
    if (error case final e?) throw e;
    return List.of(requests);
  }

  @override
  Future<void> grant(String idToken, String email) async {
    if (error case final e?) throw e;
    granted.add(email);
    requests.removeWhere((r) => r.email == email);
  }

  @override
  Future<void> dismiss(String idToken, String email) async {
    if (error case final e?) throw e;
    requests.removeWhere((r) => r.email == email);
  }

  /// The vouchers, newest first; [redeemed] records the codes redeemed, and
  /// [onRedeem] runs after a valid one (e.g. to grant the role).
  final codes = <Voucher>[];
  final redeemed = <String>[];
  void Function(String role)? onRedeem;

  @override
  Future<String> redeem(String idToken, String code) async {
    if (error case final e?) throw e;
    final i = codes.indexWhere(
      (v) =>
          v.code == code.trim().toUpperCase() &&
          !v.isUsedUp &&
          !v.isNotYetValid(DateTime.now()) &&
          !v.isExpired(DateTime.now()),
    );
    if (i < 0) throw RolesException(404);
    final v = codes[i];
    if (v.discount < 100) throw PaymentRequiredException(v.discount);
    codes[i] = Voucher(
      code: v.code,
      role: v.role,
      startsAt: v.startsAt,
      expiresAt: v.expiresAt,
      maxUses: v.maxUses,
      uses: v.uses + 1,
      createdAt: v.createdAt,
      discount: v.discount,
    );
    redeemed.add(v.code);
    onRedeem?.call(v.role);
    return v.role;
  }

  @override
  Future<List<Voucher>> vouchers(String idToken) async => List.of(codes);

  @override
  Future<Voucher> createVoucher(
    String idToken, {
    required String role,
    DateTime? startsAt,
    required DateTime expiresAt,
    required int maxUses,
    String? code,
    int discount = 100,
  }) async {
    if (error case final e?) throw e;
    final chosen = code?.trim().toUpperCase() ?? '';
    if (codes.any((v) => v.code == chosen)) throw RolesException(409);
    final voucher = Voucher(
      code: chosen.isNotEmpty
          ? chosen
          : 'TEST-CODE-${(codes.length + 2).toString().padLeft(4, '2')}',
      role: role,
      startsAt: startsAt,
      expiresAt: expiresAt,
      maxUses: maxUses,
      uses: 0,
      createdAt: DateTime.now(),
      discount: discount,
    );
    codes.insert(0, voucher);
    return voucher;
  }

  @override
  Future<void> deleteVoucher(String idToken, String code) async {
    if (error case final e?) throw e;
    codes.removeWhere((v) => v.code == code);
  }
}

/// A profile kept in memory: [members] (the owner first), the [codes]
/// that link to it, and what [link] and [unlink] were asked.
class FakeProfileClient implements ProfileClient {
  FakeProfileClient([List<ProfileAccount>? members])
    : members =
          members ??
          [
            const ProfileAccount(
              email: 'ana@example.com',
              owner: true,
              current: true,
            ),
          ];

  List<ProfileAccount> members;
  final codes = <String>[];
  final linked = <String>[];
  final unlinked = <String>[];

  /// The profile [link] joins.
  List<ProfileAccount> joins = const [
    ProfileAccount(email: 'ana@nu01.com', owner: true, current: false),
    ProfileAccount(email: 'ana@example.com', owner: false, current: true),
  ];
  Object? error;

  @override
  Future<List<ProfileAccount>> accounts(String idToken) async {
    if (error case final e?) throw e;
    return members;
  }

  @override
  Future<LinkCode> linkCode(String idToken) async {
    if (error case final e?) throw e;
    codes.add('ABCD-EFGH');
    return LinkCode(code: 'ABCD-EFGH', expiresAt: DateTime.utc(2030));
  }

  @override
  Future<List<ProfileAccount>> link(String idToken, String code) async {
    if (error case final e?) throw e;
    linked.add(code);
    return members = joins;
  }

  @override
  Future<List<ProfileAccount>> unlink(String idToken, String email) async {
    if (error case final e?) throw e;
    unlinked.add(email);
    return members = [
      for (final a in members)
        if (a.email != email) a,
    ];
  }
}

/// A device without positioning: every reading fails at once, so nothing
/// waits on the platform's location plugin (which tests don't have).
class NoLocation implements Locator {
  @override
  Future<({double latitude, double longitude, double? accuracy})> locate() =>
      Future.error(const LocationUnavailable('Location is off'));
}

/// Scrolls the Settings list until [finder] is built and on screen. It
/// drags at the list's left edge, outside the location map (a drag on the
/// map moves the map, not the list).
Future<void> scrollSettingsTo(WidgetTester tester, Finder finder) async {
  final list = find.byKey(const Key('settings-page'));
  for (var i = 0; i < 30 && finder.evaluate().isEmpty; i++) {
    final rect = tester.getRect(list);
    await tester.dragFrom(
      Offset(rect.left + 4, rect.center.dy),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
  }
  // Centered, so what's just above and below shows too.
  final scrolled = Scrollable.ensureVisible(
    tester.element(finder),
    alignment: 0.5,
  );
  await tester.pumpAndSettle();
  await scrolled;
}
