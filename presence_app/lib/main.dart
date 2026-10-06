import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory;

import 'app_log.dart';
import 'app_version.dart';
import 'auth/account_sheet.dart';
import 'battery.dart';
import 'battery_pills.dart';
import 'auth/admin_screen.dart';
import 'auth/api_config.dart';
import 'auth/auth_service.dart';
import 'auth/google_auth_service.dart';
import 'auth/membership_client.dart';
import 'auth/profile_client.dart';
import 'auth/roles_service.dart';
import 'camera_feeds.dart';
import 'clips.dart';
import 'cloud/cloud_config.dart';
import 'cloud/cloud_sync.dart';
import 'cloud/cognito.dart';
import 'cloud/s3.dart';
import 'config.dart';
import 'consent/consent_screen.dart';
import 'cameras/cameras.dart';
import 'events.dart';
import 'identity/add_device.dart';
import 'identity/join_link.dart';
import 'identity/launch_url.dart';
import 'location/device_location.dart';
import 'log_view.dart';
import 'monitoring.dart';
import 'recognition/recognizer.dart';
import 'settings.dart';
import 'status_pill.dart';
import 'system_health.dart';
import 'tab_memory.dart';
import 'storage/media_platform.dart';
import 'storage/media_store.dart';
import 'storage/persistence.dart';
import 'storage/retention.dart';
import 'theme.dart';

void main() {
  // Everything the app logs also goes to the admins' Log tab.
  AppLog.capture(() {
    WidgetsFlutterBinding.ensureInitialized();
    // On Android, to files on the phone too, for debugging after the fact.
    AppLog.instance.persistToDevice();
    runApp(const PresenceApp());
  });
}

class PresenceApp extends StatefulWidget {
  const PresenceApp({
    super.key,
    this.cameras,
    this.storage,
    this.mediaIo,
    this.now,
    this.tabMemory,
    this.auth,
    this.cloud,
    this.rolesClient,
    this.membershipClient,
    this.profileClient,
    this.consentGiven = false,
    this.locator,
    this.mapTiles,
    this.battery,
    this.links,
    this.recognizer,
  });

  /// Makes the recognizer that searches each new clip (used by tests, with
  /// fake models); defaults to [SubjectRecognizer] with the real ones.
  final SubjectRecognizer Function(
    AppEventBus bus,
    EventLog log,
    ConfigController config,
  )?
  recognizer;

  /// Overrides the links the app is opened with (used by tests); defaults
  /// to `app_links`: the page's address on web, App Links on Android.
  final Stream<Uri>? links;

  /// Skips the recording consent, as if this device had given it (used by
  /// tests). The app itself always checks storage.
  final bool consentGiven;

  /// Overrides the battery reading shown over the camera (used by tests).
  final BatteryReader? battery;

  /// Overrides the device's positioning (used by tests).
  final Locator? locator;

  /// Overrides the maps' tiles (used by tests); defaults to OpenStreetMap.
  final Widget? mapTiles;

  /// Overrides membership requests (used by tests); defaults to
  /// `/api/auth/membership`.
  final MembershipClient? membershipClient;

  /// Overrides the profile routes (used by tests); defaults to
  /// `/api/auth/profile`.
  final ProfileClient? profileClient;

  /// Overrides the auth API (used by tests); defaults to `GET /api/auth`.
  final RolesClient? rolesClient;

  /// Overrides cloud uploads (used by tests); defaults to Cognito + S3
  /// when `CloudConfig` is set, and none otherwise.
  final CloudBackend? cloud;

  /// Overrides the clock (used by tests).
  final DateTime Function()? now;

  /// Overrides where the open tab is remembered across refreshes (used by
  /// tests).
  final TabMemory? tabMemory;

  /// Overrides sign-in (used by tests); defaults to Google.
  final AuthService? auth;

  /// Overrides camera access (used by tests); defaults to the device's.
  final CameraBackend? cameras;

  /// Where app data is saved (used by tests); defaults to IndexedDB on web.
  final IdbFactory? storage;

  /// Overrides reading and replaying stored recordings (used by tests).
  final MediaIo? mediaIo;

  @override
  State<PresenceApp> createState() => _PresenceAppState();
}

class _PresenceAppState extends State<PresenceApp> {
  // Owned above MaterialApp so every route can publish to the bus, and so
  // history, settings and open cameras outlive any single screen.
  final _bus = AppEventBus();
  final _config = ConfigController();
  late final EventLog _log;
  late final Persistence _persistence;
  late final EventRetention _retention;
  late final CameraRig _rig;
  late final LocationController _location;
  late final SubjectRecognizer _recognizer;

  @override
  void initState() {
    super.initState();
    // Subscribe before publishing: a broadcast stream drops events that
    // have no listener yet.
    _log = EventLog(_bus.stream);
    _auth = widget.auth ?? GoogleAuthService();
    // The signed-in account's profile, as the auth API answers.
    _roles = RolesService(
      auth: _auth,
      client: widget.rolesClient ?? HttpRolesClient(ApiConfig.baseUrl),
    );
    final mediaIo = widget.mediaIo;
    _persistence = Persistence(
      factory: widget.storage != null
          ? Future.value(widget.storage)
          : newDefaultIdbFactory(),
      bus: _bus,
      config: _config,
      // Each event records who is signed in, and belongs to their
      // profile; none signed out.
      currentUser: () => _auth.user?.id,
      currentProfile: () => _roles.profile,
      // And records where the device is.
      currentLocation: () => _location.location,
      now: widget.now,
      mediaStore: mediaIo == null
          ? null
          : (store) => IdbMediaStore(store, mediaIo),
    );
    _location = LocationController(
      locator: widget.locator ?? DeviceLocator(),
      load: _persistence.loadLocation,
      save: _persistence.saveLocation,
      now: widget.now,
    );
    _location.init().ignore();
    // Settings restored from the cloud include the location set on the map.
    _persistence.onRemoteLocation = _location.applyRemote;
    // Finds the subjects on each new clip once it's recorded.
    _recognizer =
        widget.recognizer?.call(_bus, _log, _config) ??
        SubjectRecognizer(bus: _bus, log: _log, config: _config);
    _bus.publish(AppEvent.appStarted());
    _auth.addListener(_onAuthChanged);
    _rig = CameraRig(
      backend: widget.cameras ?? DeviceCameras(),
      config: _config,
      bus: _bus,
      now: widget.now,
    );
    _auth.init().ignore();
    _roles.addListener(_onProfileChanged);
    final cloud =
        widget.cloud ??
        (CloudConfig.enabled
            ? AwsCloudBackend(
                cognito: CognitoCredentials(
                  region: CloudConfig.region,
                  api: ApiConfig.baseUrl,
                ),
                bucket: S3Bucket(
                  bucket: CloudConfig.userDataBucket,
                  region: CloudConfig.region,
                ),
              )
            : null);
    _sync = cloud == null
        ? null
        : CloudSync(
            auth: _auth,
            // Only users with a role sync.
            roles: _roles,
            backend: cloud,
            now: widget.now,
            store: _persistence.store,
            media: _persistence.media,
            changes: _persistence.changes,
            // Not what the device deletes as too old.
            keep: () => _config.config.history.keep,
            // And this device's settings, kept per device.
            settings: _persistence,
            // Clips and events fetched from the cloud after sign-in join the
            // local history, like a restore from IndexedDB.
            // A Capture all request from another device takes a clip here.
            onRemote: (remote) async {
              final events = await _persistence.importRemote(
                events: remote.events,
                clips: remote.clips,
              );
              _log.addHistory(events);
              // Events changed on another device: their tags as they are
              // there now, on screen too.
              await _persistence.updateFromRemote(remote.updated, _log.events);
              _rig.answerCaptureAll(events, deviceId: _deviceId);
            },
          );
    // A clip fetched from the cloud plays before its recording has come
    // down: it's downloaded then.
    _persistence.fetchMissingMedia = _sync?.fetchRecording;
    _persistence
      ..attachRig(_rig)
      ..restore(_log).catchError((Object e) {
        debugPrint('Presence: could not restore saved data: $e');
      });
    // Deletes events older than the History setting: now, once the history
    // is restored, and every 3 h.
    _retention = EventRetention(
      delete: _persistence.deleteEventsBefore,
      config: _config,
      now: widget.now,
    )..start();
    _persistence.deviceId.then((id) {
      if (mounted) setState(() => _deviceId = id);
    }, onError: (Object e) => debugPrint('Presence: no device ID: $e'));
    _checkConsent();
    requestPersistentStorage().ignore();
    // Opened with a link to add this device: the first one, and any while
    // running.
    _links = (widget.links ?? AppLinks().uriLinkStream).listen((uri) {
      final join = JoinLink.parse(uri);
      if (join != null && mounted) setState(() => _join = join);
    }, onError: (Object e) => debugPrint('Presence: no launch link: $e'));
  }

  StreamSubscription<Uri>? _links;

  /// The link this device was opened with to join a user's devices, until
  /// it's handled or dismissed.
  JoinLink? _join;

  void _joinHandled() {
    clearLaunchQuery();
    setState(() => _join = null);
  }

  /// This device's ID, once storage has it.
  String? _deviceId;

  /// Whether this device gave its recording consent: null while checking,
  /// before anything shows. The cameras open (and record) only once it's
  /// given.
  bool? _consented;

  Future<void> _checkConsent() async {
    var given = widget.consentGiven;
    if (!given) {
      try {
        given = await _persistence.hasConsent();
      } catch (e) {
        // Can't tell: ask.
        debugPrint('Presence: could not read the consent: $e');
      }
    }
    if (!mounted) return;
    setState(() => _consented = given);
    if (given) _openCameras();
  }

  /// Opens the cameras once the saved settings are loaded, so the camera
  /// picked with Flip last time opens first, not the default one. Storage
  /// that never answers mustn't keep the camera closed: after a few seconds
  /// it opens anyway (and switches when the settings arrive).
  void _openCameras() {
    var opened = false;
    void open() {
      if (opened || !mounted) return;
      opened = true;
      _settingsWait?.cancel();
      _rig.load();
    }

    _settingsWait?.cancel();
    _settingsWait = Timer(const Duration(seconds: 5), () {
      debugPrint('Presence: settings still loading; opening the camera');
      open();
    });
    _persistence.configLoaded.then((_) => open());
  }

  /// The longest [_openCameras] waits for the saved settings.
  Timer? _settingsWait;

  /// The user agreed on the consent screen: saved once, never asked again
  /// on this device. If saving fails, this session goes on and the next
  /// launch asks again.
  Future<void> _agree() async {
    final at = (widget.now ?? DateTime.now)();
    try {
      await _persistence.giveConsent(at);
    } catch (e) {
      debugPrint('Presence: could not save the consent: $e');
    }
    if (!mounted) return;
    _bus.publish(
      AppEvent(
        icon: Icons.verified_user,
        title: 'Recording consent given',
        detail: _deviceId,
        time: at,
      ),
    );
    setState(() => _consented = true);
    _openCameras();
  }

  /// The profile whose events were last claimed; null signed out.
  String? _claimedFor;

  /// Once the auth API answers a sign-in (or a session restored at launch)
  /// with the account's profile, the events recorded here without one
  /// become that profile's.
  void _onProfileChanged() {
    final profile = _roles.profile;
    final user = _auth.user;
    if (profile == _claimedFor) return;
    _claimedFor = profile;
    if (profile == null || user == null) return;
    _persistence
        .claimForProfile(profile, user.id)
        .catchError(
          (Object e) => debugPrint('Presence: could not claim events: $e'),
        );
  }

  late final AuthService _auth;
  late final RolesService _roles;
  late final MembershipClient _membership =
      widget.membershipClient ?? HttpMembershipClient(ApiConfig.baseUrl);
  late final ProfileClient _profiles =
      widget.profileClient ?? HttpProfileClient(ApiConfig.baseUrl);
  CloudSync? _sync;
  String? _signedInAs;

  /// Sign-ins and sign-outs go on the event stream too.
  void _onAuthChanged() {
    final email = _auth.user?.email;
    if (email == _signedInAs) return;
    final previous = _signedInAs;
    _signedInAs = email;
    _bus.publish(
      email != null
          ? AppEvent(icon: Icons.login, title: 'Signed in', detail: email)
          : AppEvent(icon: Icons.logout, title: 'Signed out', detail: previous),
    );
  }

  @override
  void dispose() {
    _settingsWait?.cancel();
    _auth.removeListener(_onAuthChanged);
    _links?.cancel();
    _sync?.dispose();
    _roles.dispose();
    _location.dispose();
    _recognizer.dispose();
    _retention.dispose();
    _persistence.dispose();
    _rig.dispose();
    _log.dispose();
    _bus.close();
    _config.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppEventBusScope(
      bus: _bus,
      child: SubjectRecognizerScope(
        recognizer: _recognizer,
        child: MaterialApp(
          title: AppVersion.title,
          debugShowCheckedModeBanner: false,
          theme: gruvboxSoftDarkTheme(),
          home: switch (_consented) {
            // Nothing shows until the device's consent is known.
            null => const Scaffold(
              body: Center(
                child: CircularProgressIndicator(key: Key('checking-consent')),
              ),
            ),
            false => ConsentScreen(onAgree: _agree),
            true => HomeScreen(
              log: _log,
              rig: _rig,
              config: _config,
              auth: _auth,
              roles: _roles,
              membership: _membership,
              profiles: _profiles,
              sync: _sync,
              deviceId: _deviceId,
              location: _location,
              mapTiles: widget.mapTiles,
              battery: widget.battery,
              join: _join,
              onJoinHandled: _joinHandled,
              tabMemory: widget.tabMemory,
            ),
          },
        ),
      ),
    );
  }
}

/// The top-level destinations, as tabs in the app bar.
enum HomeTab {
  camera('Camera', Icons.videocam),
  monitoring('Monitoring', Icons.monitor_heart),
  settings('Settings', Icons.settings),

  /// Admins only, when Settings' switch shows it (on by default in DEV,
  /// whose anonymous user is a root); after the always-shown tabs, so they
  /// keep their index.
  log('Log', Icons.receipt_long),

  /// Signed-in admins only (not DEV: there are no accounts): membership
  /// requests and voucher codes ([AdminView]). Last; with the Log tab
  /// hidden it takes the Log's place, so map a tab to its controller index
  /// through the shown tabs, never by [HomeTab.index] alone.
  admin('Admin', Icons.admin_panel_settings);

  const HomeTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The app's one screen: a tab bar in the top right of the app bar flips
/// between the full-screen camera (the start tab), monitoring (the subjects'
/// map, the subjects and the event stream), the settings (with the device's
/// location map), for admins who turned it on the log, and for signed-in
/// admins the Admin page (membership requests and vouchers). Swiping
/// sideways flips too,
/// except on Monitoring (its map) and while a finger is on the Settings map.
///
/// Signed out, the camera still shows, but the navigation is hidden: the
/// app bar has only a sign-in button, and the screen stays on
/// the camera.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.log,
    required this.rig,
    required this.config,
    required this.auth,
    required this.roles,
    required this.membership,
    required this.profiles,
    this.sync,
    this.deviceId,
    required this.location,
    this.mapTiles,
    this.battery,
    this.join,
    this.onJoinHandled,
    this.tabMemory,
  });

  /// Where the open tab is remembered, so a browser refresh comes back to
  /// it; defaults to the platform's ([TabMemory]).
  final TabMemory? tabMemory;

  /// The link this device was opened with to become one of a user's
  /// devices ([JoinLink]), until handled: a banner says what's left to do.
  final JoinLink? join;

  /// The join link was handled (joined) or dismissed.
  final VoidCallback? onJoinHandled;

  /// The battery reading over the camera, when not the device's (tests).
  final BatteryReader? battery;

  /// Where this device is (the Settings map, and every event).
  final LocationController location;

  /// The maps' tiles, when not OpenStreetMap's (tests).
  final Widget? mapTiles;

  /// This device's ID (shown in Settings), once it's loaded.
  final String? deviceId;

  /// The signed-in user's roles: events and features need `presence_user`,
  /// the Admin tab `presence_admin`.
  final RolesService roles;

  /// Membership requests: sent from the sign-up sheet, approved on the
  /// Admin tab.
  final MembershipClient membership;

  /// The user's linked Google accounts (account and sign-up sheets).
  final ProfileClient profiles;

  final EventLog log;
  final CameraRig rig;
  final ConfigController config;
  final AuthService auth;

  /// Cloud uploads, when configured (their status shows in the account
  /// sheet).
  final CloudSync? sync;

  /// Width of each icon tab: Material's 48 dp minimum touch target.
  static const double tabWidth = 48;

  /// How narrow tabs get when the app bar can't fit them at [tabWidth]
  /// (an admin's, with the Log and Admin tabs, on a 320 dp phone).
  static const double minTabWidth = 40;

  /// How long a message over the camera stays.
  static const Duration messageFor = Duration(seconds: 4);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late TabController _tabs;

  /// The tabs [_tabs] was made for, in order: what the tab bar and its
  /// pages show, so they always match the controller's length.
  late List<HomeTab> _tabList;

  /// The Log tab shows for admins (so in DEV too: the anonymous user is a
  /// root there) when Settings' switch is on: by default in DEV only.
  bool get _showLog =>
      widget.roles.isAdmin && widget.config.log.showIn(dev: _dev);

  /// The Admin tab shows for signed-in admins, not in DEV (there are no
  /// accounts).
  bool get _showAdmin => !_dev && widget.roles.isAdmin;

  /// The tabs to show, in [HomeTab] order. A tab's controller index is its
  /// place here ([_indexOf]): the Admin tab's moves when the Log's hides.
  List<HomeTab> get _shownTabs => [
    for (final tab in HomeTab.values)
      if (switch (tab) {
        HomeTab.log => _showLog,
        HomeTab.admin => _showAdmin,
        _ => true,
      })
        tab,
  ];

  /// [tab]'s index in the tab bar, or -1 when it isn't shown.
  int _indexOf(HomeTab tab) => _tabList.indexOf(tab);

  /// The open tab.
  HomeTab get _tab => _tabList[_tabs.index];

  /// A controller for the [_shownTabs], open on [tab] (or the camera, if
  /// it isn't shown).
  TabController _newTabs(HomeTab tab) {
    _tabList = _shownTabs;
    return TabController(
      length: _tabList.length,
      initialIndex: _indexOf(tab).clamp(0, _tabList.length - 1),
      vsync: this,
    )..addListener(_onTabChanged);
  }

  /// Adds or removes the Log and Admin tabs when the roles or the Log
  /// switch change, staying on the same tab (or, if it goes, the nearest
  /// one before it).
  void _syncTabs() {
    final shown = _shownTabs;
    if (listEquals(shown, _tabList)) return;
    final old = _tabs..removeListener(_onTabChanged);
    final stay = _tabList
        .take(old.index + 1)
        .lastWhere(shown.contains, orElse: () => HomeTab.camera);
    _tabs = _newTabs(stay);
    // The tab bar lets go of it in this frame's build.
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  late final TabMemory _tabMemory = widget.tabMemory ?? TabMemory();

  /// The tab open before a refresh, until the tabs can show (access is
  /// known only once the roles load).
  HomeTab? _restoreTab;

  void _onTabChanged() {
    if (!_tabs.indexIsChanging) {
      _tabMemory.write(_tab.name);
    }
    setState(() {});
  }

  /// Opens the tab remembered from before a refresh, once there's access.
  void _restore() {
    final tab = _restoreTab;
    if (tab == null || !_hasAccess) return;
    _restoreTab = null;
    final index = _indexOf(tab);
    if (index >= 0) _tabs.index = index;
  }

  bool get _onCamera => _tab == HomeTab.camera;

  /// The battery, shown over the camera; read every minute and on
  /// charging changes.
  late final _battery = BatteryController(widget.battery ?? DeviceBattery());

  /// A finger is on the Settings location map: no swiping to other tabs,
  /// so a drag moves the map.
  bool _mapHeld = false;

  bool get _onMonitoring => _tab == HomeTab.monitoring;

  /// The event the Monitoring tab's timeline scrolls to and outlines.
  final _focusedEvent = ValueNotifier<String?>(null);

  /// The Camera tab's view button, All: this device's camera in a grid
  /// with every other device's latest image.
  bool _showAll = false;

  /// What the view button shows: One (this camera), All (the grid) or None
  /// (the camera off: [CameraRig.paused], kept in the settings).
  CameraViewMode get _viewMode => widget.rig.paused
      ? CameraViewMode.none
      : _showAll
      ? CameraViewMode.all
      : CameraViewMode.one;

  /// One → All → None → One.
  void _nextViewMode() {
    switch (_viewMode) {
      case CameraViewMode.one:
        setState(() => _showAll = true);
      case CameraViewMode.all:
        setState(() => _showAll = false);
        widget.rig.setPaused(true);
      case CameraViewMode.none:
        widget.rig.setPaused(false);
    }
  }

  /// The one device whose events the Monitoring tab shows, picked by
  /// tapping an event's device: none at launch, so every device's events
  /// show, and kept while switching tabs.
  final _onlyDevice = ValueNotifier<String?>(null);

  /// The Monitoring tab's "Show system events" toggle: on in DEV, off
  /// otherwise (only grabs), and kept while switching tabs. Made on first
  /// use, once the execution mode is known.
  late final _showSystemEvents = ValueNotifier(_dev);

  /// The Monitoring tab's events search: blank at launch, and kept while
  /// switching tabs.
  final _eventSearch = ValueNotifier('');

  /// Shows [event] in the Monitoring tab's timeline, closing any screen over
  /// the tabs (a subject's).
  void _openEvent(AppEvent event) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    _tabs.animateTo(_indexOf(HomeTab.monitoring));
    // Cleared first, so asking for the same event again still scrolls.
    _focusedEvent
      ..value = null
      ..value = event.id;
  }

  bool get _signedIn => widget.auth.user != null;

  /// No sign-in configured ([ExecutionMode.dev]): everything but what's
  /// about accounts (sign-in, the account, sign-up and Admin).
  bool get _dev => widget.roles.mode == ExecutionMode.dev;

  /// Signed in as a `presence_user`, or [_dev]: the tabs, the camera's
  /// buttons and (signed in) cloud sync.
  bool get _hasAccess => _dev || (_signedIn && widget.roles.hasAccess);

  @override
  void initState() {
    super.initState();
    _tabs = _newTabs(HomeTab.camera);
    widget.auth.addListener(_onAuthChanged);
    widget.roles.addListener(_onAccessChanged);
    widget.config.addListener(_onConfigChanged);
    _restoreTab = HomeTab.values.asNameMap()[_tabMemory.read()];
    _restore();
  }

  /// Losing access hides the other tabs, so go back to the camera.
  void _onAccessChanged() {
    _syncTabs();
    if (!_hasAccess) _tabs.index = _indexOf(HomeTab.camera);
    _restore();
    if (mounted) setState(() {});
  }

  /// Settings' Log switch adds or removes the Log tab.
  void _onConfigChanged() {
    if (listEquals(_tabList, _shownTabs)) return;
    _syncTabs();
    _restore();
    if (mounted) setState(() {});
  }

  String? _shownError;

  /// Signing out hides the navigation, so go back to the camera. Sign-in
  /// errors pop a message (there's no sign-in screen to show them on).
  void _onAuthChanged() {
    if (!_hasAccess) _tabs.index = _indexOf(HomeTab.camera);
    _restore();
    final error = widget.auth.error;
    if (error != null && error != _shownError && mounted) {
      _showMessage(
        CameraMessage(
          icon: Icons.error_outline,
          label: 'Sign-in failed: $error',
          error: true,
        ),
        elsewhere: true,
      );
    }
    _shownError = error;
    setState(() {});
  }

  /// The join link that was announced as joined, so it's announced once.
  JoinLink? _announced;

  /// Where [HomeScreen.join] stands. Once joined, a message says so and the
  /// link is done.
  JoinStatus? _joinStatus() {
    final join = widget.join;
    if (join == null) return null;
    final status = JoinStatus.of(
      join,
      deviceId: widget.deviceId,
      userId: widget.auth.user?.id,
      checking: widget.auth.checking,
      dev: _dev,
    );
    if (status == JoinStatus.joined && _announced != join) {
      _announced = join;
      final email = widget.auth.user?.email;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showMessage(
          CameraMessage(
            icon: Icons.devices,
            label: email == null
                ? 'Presence is open on this device: ${widget.deviceId}'
                : 'This device is now one of $email\'s: ${widget.deviceId}',
          ),
          elsewhere: true,
        );
        widget.onJoinHandled?.call();
      });
    }
    return status;
  }

  /// The message over the camera, a pill after the readiness pill, for
  /// [HomeScreen.messageFor]; null when there's none.
  CameraMessage? _message;
  Timer? _messageTimer;

  /// Shows [message]: on the Camera tab as a pill after the readiness one,
  /// so nothing over the camera moves or is covered; a newer message
  /// replaces it. On the other tabs, a snackbar if [elsewhere], else
  /// nothing.
  void _showMessage(CameraMessage message, {bool elsewhere = false}) {
    if (!_onCamera) {
      if (elsewhere) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message.label)));
      }
      return;
    }
    _messageTimer?.cancel();
    _messageTimer = Timer(HomeScreen.messageFor, () {
      if (mounted) setState(() => _message = null);
    });
    setState(() => _message = message);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    widget.roles.removeListener(_onAccessChanged);
    widget.config.removeListener(_onConfigChanged);
    _clipEvents?.cancel();
    _messageTimer?.cancel();
    _focusedEvent.dispose();
    _onlyDevice.dispose();
    _showSystemEvents.dispose();
    _eventSearch.dispose();
    _battery.dispose();
    _tabs.dispose();
    super.dispose();
  }

  StreamSubscription<AppEvent>? _clipEvents;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Every clip that starts (button or motion) pops a message.
    _clipEvents ??= AppEventBusScope.of(context).stream.listen(_onEvent);
  }

  void _onEvent(AppEvent event) {
    if (event is! ClipRequested || event.clip.capture == null || !mounted) {
      return;
    }
    final after = event.clip.after.inSeconds;
    final started = switch (event.trigger) {
      ClipTrigger.motion => 'Motion detected',
      ClipTrigger.scheduled => 'Scheduled clip',
      ClipTrigger.startup => 'Startup clip',
      ClipTrigger.manual => 'Clip started',
      ClipTrigger.all => 'Capture all',
    };
    // After any clip, the readiness pill carries the cooldown.
    _showMessage(
      CameraMessage(
        icon: event.icon,
        label: '$started · saving the next $after s',
        opensEvents: true,
      ),
    );
  }

  /// [HomeScreen.tabWidth], or less (down to [HomeScreen.minTabWidth])
  /// when the tabs, the buttons after them and the dev label's edge don't
  /// fit the screen.
  double _tabWidth(BuildContext context) {
    // The account button (none in DEV) and the gap after it.
    final buttons = (_dev ? 0 : 48) + 4;
    const titleRoom = 12 + 16;
    final fit =
        (MediaQuery.sizeOf(context).width - titleRoom - buttons) / _tabs.length;
    return fit.clamp(HomeScreen.minTabWidth, HomeScreen.tabWidth);
  }

  /// The Clip button: this camera's clip; with the All grid showing, a
  /// Capture all request too, which cloud sync takes to the profile's other
  /// devices so each takes a clip ([CameraRig.answerCaptureAll]).
  Future<void> _clip() {
    final bus = AppEventBusScope.of(context);
    if (!(_showAll && _hasAccess)) return widget.rig.requestClips(bus);
    bus.publish(AppEvent.captureAll());
    return widget.rig.requestClips(bus, trigger: ClipTrigger.all);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Nothing shows until the auth API says how the system runs.
    if (widget.roles.state == AccessState.starting) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(key: Key('starting'))),
      );
    }
    final joinStatus = _joinStatus();
    return Scaffold(
      // The camera runs edge to edge, under the app bar.
      extendBodyBehindAppBar: true,
      backgroundColor: _onCamera ? Colors.black : scheme.surface,
      appBar: AppBar(
        // No title: only the "dev" label, in DEV.
        titleSpacing: 12,
        title: _dev
            ? const Row(children: [Flexible(child: DevModeLabel())])
            : null,
        backgroundColor: _onCamera ? Colors.transparent : scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        // Over the camera, a scrim keeps the tabs readable.
        flexibleSpace: _onCamera
            ? const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
              )
            : null,
        actions: [
          if (!_hasAccess && !_signedIn) ...[
            SignInAction(auth: widget.auth),
            const SizedBox(width: 12),
          ] else if (!_hasAccess) ...[
            // Signed in without a role: only their account, and sign-up.
            if (widget.roles.state == AccessState.checking)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox.square(
                  key: Key('checking-access'),
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              SignUpButton(
                auth: widget.auth,
                roles: widget.roles,
                membership: widget.membership,
                profiles: widget.profiles,
              ),
            AccountButton(
              auth: widget.auth,
              roles: widget.roles,
              profiles: widget.profiles,
              log: widget.log,
              deviceId: widget.deviceId,
            ),
            const SizedBox(width: 4),
          ] else ...[
            SizedBox(
              width: _tabWidth(context) * _tabs.length,
              child: TabBar(
                controller: _tabs,
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.tab,
                labelPadding: EdgeInsets.zero,
                tabs: [
                  for (final tab in _tabList)
                    Tooltip(
                      message: tab.label,
                      child: Tab(
                        icon: Icon(tab.icon, semanticLabel: tab.label),
                      ),
                    ),
                ],
              ),
            ),
            // Account (who's signed in, sign out, about): an action, not a
            // tab.
            if (!_dev)
              AccountButton(
                auth: widget.auth,
                sync: widget.sync,
                roles: widget.roles,
                profiles: widget.profiles,
                log: widget.log,
                deviceId: widget.deviceId,
              ),
            const SizedBox(width: 4),
          ],
        ],
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabs,
            // No swiping to the other tabs while they're hidden, nor on the
            // maps: there, a drag moves the map.
            physics: _hasAccess && !_onMonitoring && !_mapHeld
                ? null
                : const NeverScrollableScrollPhysics(),
            children: [
              _KeepAlive(
                child: CameraFeedsView(
                  key: const Key('camera-page'),
                  rig: widget.rig,
                  log: widget.log,
                  deviceId: widget.deviceId,
                  profileId: widget.roles.profile,
                  showAll: _showAll && _hasAccess,
                ),
              ),
              SafeArea(
                child: MonitoringView(
                  log: widget.log,
                  config: widget.config,
                  tiles: widget.mapTiles,
                  onOpenEvent: _openEvent,
                  focus: _focusedEvent,
                  deviceId: widget.deviceId,
                  profileId: widget.roles.profile,
                  onlyDevice: _onlyDevice,
                  showSystemEvents: _showSystemEvents,
                  search: _eventSearch,
                ),
              ),
              // Full width, with the device's location map.
              SafeArea(
                child: SettingsView(
                  config: widget.config,
                  motionLevel: widget.rig.motionLevel,
                  nextClip: ScheduledClipCountdown(rig: widget.rig),
                  deviceId: widget.deviceId,
                  profileId: widget.roles.profile,
                  health: SystemHealth(roles: widget.roles, sync: widget.sync),
                  addDevice: switch (widget.deviceId) {
                    final deviceId? => AddDeviceSection(
                      link: JoinLink.build(
                        from: deviceId,
                        userId: _dev ? null : widget.auth.user?.id,
                      ),
                      email: _dev ? null : widget.auth.user?.email,
                    ),
                    null => null,
                  },
                  location: widget.location,
                  tiles: widget.mapTiles,
                  onMapHeld: (held) => setState(() => _mapHeld = held),
                  logTabDefault: widget.roles.isAdmin ? _dev : null,
                ),
              ),
              if (_tabList.contains(HomeTab.log))
                SafeArea(
                  child: LogView(
                    log: AppLog.instance,
                    health: HealthPanel(
                      roles: widget.roles,
                      sync: widget.sync,
                      events: widget.log,
                      profileId: widget.roles.profile,
                      deviceId: widget.deviceId,
                    ),
                  ),
                ),
              // Membership requests and vouchers: a page like the others,
              // with no back button of its own.
              if (_tabList.contains(HomeTab.admin))
                SafeArea(
                  child: AdminView(
                    auth: widget.auth,
                    membership: widget.membership,
                    canCreateAdmins: widget.roles.isRoot,
                  ),
                ),
            ],
          ),
          // Bottom left, across from Flip and Clip: a failed health check,
          // the battery, whether a clip now would be complete, and after it
          // the latest message. Signed out, only the message.
          if (_onCamera && (_hasAccess || _message != null))
            _CameraStatus(
              rig: widget.rig,
              battery: _battery,
              full: _hasAccess,
              // Tapping it opens the health panel (Log), or for non-admins
              // the health line (Settings).
              roles: widget.roles,
              sync: widget.sync,
              onHealthTap: () => _tabs.animateTo(
                _indexOf(
                  _tabList.contains(HomeTab.log)
                      ? HomeTab.log
                      : HomeTab.settings,
                ),
              ),
              message: switch (_message) {
                final m? => CameraMessagePill(
                  message: m,
                  // The events tab is only there with access.
                  onView: m.opensEvents && _hasAccess
                      ? () => _tabs.animateTo(_indexOf(HomeTab.monitoring))
                      : null,
                ),
                null => null,
              },
            ),
          // Opened with a link to add this device: what's left to do.
          if (joinStatus != null)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: JoinBanner(
                    status: joinStatus,
                    email: widget.auth.user?.email,
                    onSignOut: widget.auth.signOut,
                    onDismiss: () => widget.onJoinHandled?.call(),
                  ),
                ),
              ),
            ),
        ],
      ),
      // Signed out, the camera shows with no buttons at all.
      floatingActionButton: _onCamera && _hasAccess
          ? ListenableBuilder(
              listenable: widget.rig,
              // Each button is hidden, not disabled, when it can't act.
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  // Shows what's on screen (One, All, None); a tap moves
                  // on to the next. Highlighted for All, and for None, the
                  // camera off.
                  // Icon only: the tooltip and screen readers name it.
                  FloatingActionButton(
                    key: const Key('show-all'),
                    heroTag: 'show-all',
                    tooltip: switch (_viewMode) {
                      CameraViewMode.one => 'Show all devices',
                      CameraViewMode.all => 'Turn the camera off',
                      CameraViewMode.none => 'Turn the camera on',
                    },
                    backgroundColor: switch (_viewMode) {
                      CameraViewMode.one => scheme.surfaceContainerHigh,
                      CameraViewMode.all => scheme.secondaryContainer,
                      CameraViewMode.none => scheme.errorContainer,
                    },
                    foregroundColor: switch (_viewMode) {
                      CameraViewMode.one => scheme.onSurface,
                      CameraViewMode.all => scheme.onSecondaryContainer,
                      CameraViewMode.none => scheme.onErrorContainer,
                    },
                    onPressed: _nextViewMode,
                    child: Icon(switch (_viewMode) {
                      CameraViewMode.one => Icons.crop_square,
                      CameraViewMode.all => Icons.grid_view,
                      CameraViewMode.none => Icons.videocam_off,
                    }),
                  ),
                  if (widget.rig.devices.length > 1 && !widget.rig.paused)
                    FloatingActionButton(
                      heroTag: 'flip-camera',
                      tooltip: 'Flip camera',
                      // Secondary action: quieter than Clip.
                      backgroundColor: scheme.surfaceContainerHigh,
                      foregroundColor: scheme.onSurface,
                      onPressed: widget.rig.canFlip ? widget.rig.flip : null,
                      child: const Icon(Icons.cameraswitch),
                    ),
                  if (widget.rig.canClip)
                    FloatingActionButton.extended(
                      heroTag: 'clip',
                      tooltip: 'Clip',
                      icon: const Icon(Icons.camera),
                      label: const Text('Clip'),
                      onPressed: _clip,
                    ),
                ],
              ),
            )
          : null,
    );
  }
}

/// Whether an automatic clip can be taken now: ready, or counting down the
/// cooldown after the latest clip (red while its "after" part is still
/// being saved). The Clip button works either way.
class ReadinessIndicator extends StatefulWidget {
  const ReadinessIndicator({super.key, required this.rig});

  final CameraRig rig;

  @override
  State<ReadinessIndicator> createState() => _ReadinessIndicatorState();
}

class _ReadinessIndicatorState extends State<ReadinessIndicator> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    // Readiness moves with time: refresh the countdowns.
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final readiness = widget.rig.readiness;
    final seconds = (readiness.remaining.inMilliseconds / 1000).ceil();
    // Minutes and seconds for the cooldown ("4:59"), seconds below
    // a minute ("45 s").
    final countdown = seconds >= 60
        ? '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}'
        : '$seconds s';
    // Only the dot, and the countdown while there is one: the tooltip and
    // screen readers spell the state out.
    final (
      Widget leading,
      String? label,
      String semantics,
    ) = switch (readiness.state) {
      ClipReadinessState.ready => (
        _Dot(color: Gruvbox.green),
        null,
        'Ready to clip',
      ),
      ClipReadinessState.cooldown => (
        // Red while the latest clip is still saving, then amber.
        _Dot(color: readiness.recording ? Gruvbox.red : Gruvbox.yellow),
        countdown,
        readiness.recording
            ? 'Clip saving; next automatic clip in $countdown'
            : 'Next automatic clip in $countdown',
      ),
      ClipReadinessState.unavailable => (
        _Dot(color: scheme.outline),
        null,
        'Camera not ready',
      ),
      ClipReadinessState.paused => (
        _Dot(color: scheme.outline),
        null,
        'Camera off: nothing is recorded',
      ),
    };
    return StatusPill(
      key: const Key('readiness'),
      leading: leading,
      label: label,
      semantics: semantics,
    );
  }
}

/// A message over the camera: a clip that started, a sign-in that failed.
@immutable
class CameraMessage {
  const CameraMessage({
    required this.icon,
    required this.label,
    this.opensEvents = false,
    this.error = false,
  });

  final IconData icon;
  final String label;

  /// Tapping it opens Monitoring, where its event is (a clip).
  final bool opensEvents;

  /// Something went wrong: its icon is in the error color.
  final bool error;
}

/// A [CameraMessage] as a pill after the readiness one, where it moves and
/// covers nothing; tapping it opens the clip's event ([onView]), where
/// there's one and access. A label too long for the room is cut short; the
/// tooltip has it all.
class CameraMessagePill extends StatelessWidget {
  const CameraMessagePill({super.key, required this.message, this.onView});

  final CameraMessage message;
  final VoidCallback? onView;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = message.label;
    final pill = StatusPill(
      key: const Key('camera-message'),
      leading: Icon(
        message.icon,
        size: 18,
        color: message.error ? scheme.error : scheme.primary,
      ),
      label: label,
      semantics: onView == null ? label : '$label. Tap to view it.',
    );
    if (onView == null) return pill;
    return GestureDetector(onTap: onView, child: pill);
  }
}

/// The status pills over the camera, bottom left, across from Flip and
/// Clip: a failed health check ([HealthWarningPill]), the battery, its temperature
/// (Android), the readiness and, beside it, a clip that just started
/// ([message]). In a row, level with the
/// buttons and clear of them, on wide screens. On phones they stack,
/// starting just above the buttons' row, so however wide they are they
/// never run into Flip and Clip; the readiness and the message share the
/// lowest line. A label that doesn't fit is cut short.
class _CameraStatus extends StatelessWidget {
  const _CameraStatus({
    required this.rig,
    required this.battery,
    required this.roles,
    this.sync,
    this.full = true,
    this.onHealthTap,
    this.message,
  });

  final CameraRig rig;
  final BatteryController battery;

  /// With access: the health warning, battery and readiness too. Signed
  /// out, only [message].
  final bool full;

  /// The health checks', for [HealthWarningPill].
  final RolesService roles;
  final CloudSync? sync;

  /// Where tapping the health warning goes.
  final VoidCallback? onHealthTap;

  /// The pill saying a clip just started, if one did.
  final Widget? message;

  /// Room kept on the right for the view button, Flip and Clip when the
  /// pills are in a row.
  static const double buttonsRoom = 16 + 56 + 12 + 56 + 12 + 120;

  /// Narrower than this, the pills stack.
  static const double stackBelow = 600;

  /// The floating buttons' height, and the gap above them.
  static const double buttonRow = 56 + 8;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final stacked = MediaQuery.sizeOf(context).width < stackBelow;
    return Positioned(
      // 16 from the edges, like the floating buttons; in a row, centered
      // on them (the pills are 40 high, the buttons 56).
      left: 16 + padding.left,
      right: (stacked ? 16 : buttonsRoom) + padding.right,
      bottom: 16 + padding.bottom + (stacked ? buttonRow : (56 - 40) / 2),
      // At the start of the room given; the pills keep their own width.
      child: Align(
        alignment: AlignmentDirectional.bottomStart,
        child: ListenableBuilder(
          listenable: Listenable.merge([rig, battery, roles, ?sync]),
          builder: (context, _) {
            final reading = full ? battery.reading : null;
            final readiness = full && (rig.active != null || rig.paused)
                ? ReadinessIndicator(rig: rig)
                : null;
            final failed = full
                ? HealthWarningPill.failedChecks(roles, sync)
                : const <String>[];
            final batteryPills = [
              if (failed.isNotEmpty)
                HealthWarningPill(failed: failed, onTap: onHealthTap),
              if (reading != null) BatteryPill(battery: battery),
              if (reading?.celsius != null)
                BatteryTemperaturePill(battery: battery),
            ];
            // The readiness, and the message beside it, cut short if need be.
            final last = [
              ?readiness,
              if (message case final m?) Flexible(child: m),
            ];
            return stacked
                ? Column(
                    key: const Key('camera-status'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      ...batteryPills,
                      if (last.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 8,
                          children: last,
                        ),
                    ],
                  )
                : Row(
                    key: const Key('camera-status'),
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [...batteryPills, ...last],
                  );
          },
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Keeps a tab's page (and its live camera views) alive while other tabs
/// are shown.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});

  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// Says, quietly, that the system runs in [ExecutionMode.dev]: nobody signs
/// in and everything is open. With a build version, it shows it too
/// ("dev 0.4.202610011728"), cut short with an ellipsis where there's no
/// room.
class DevModeLabel extends StatelessWidget {
  const DevModeLabel({super.key, this.version = AppVersion.version});

  /// The build's version ([AppVersion.version]); empty shows only "dev".
  final String version;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = version.isEmpty ? 'dev' : 'dev $version';
    return Tooltip(
      message:
          'Development mode${version.isEmpty ? '' : ', version $version'}: '
          'sign-in isn\'t configured, so everything is open to everyone.',
      child: Container(
        key: const Key('dev-mode'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // labelLarge (14 sp): readable next to the title.
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// What the Camera tab shows, chosen with its view button.
enum CameraViewMode {
  /// This device's camera, full screen.
  one,

  /// This device's camera in a grid with every other device's image.
  all,

  /// Nothing: the camera is off ([CameraRig.paused]).
  none,
}
