import 'dart:async';

import 'package:flutter/material.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory;

import 'app_version.dart';
import 'auth/account_sheet.dart';
import 'battery.dart';
import 'battery_pills.dart';
import 'auth/admin_screen.dart';
import 'auth/api_config.dart';
import 'auth/auth_service.dart';
import 'auth/google_auth_service.dart';
import 'auth/membership_client.dart';
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
import 'location/device_location.dart';
import 'monitoring.dart';
import 'recognition/recognizer.dart';
import 'settings.dart';
import 'status_pill.dart';
import 'system_health.dart';
import 'storage/media_platform.dart';
import 'storage/media_store.dart';
import 'storage/persistence.dart';
import 'theme.dart';

void main() {
  runApp(const PresenceApp());
}

class PresenceApp extends StatefulWidget {
  const PresenceApp({
    super.key,
    this.cameras,
    this.storage,
    this.mediaIo,
    this.now,
    this.auth,
    this.cloud,
    this.rolesClient,
    this.membershipClient,
    this.consentGiven = false,
    this.locator,
    this.mapTiles,
    this.battery,
  });

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

  /// Overrides the auth API (used by tests); defaults to `GET /api/auth`.
  final RolesClient? rolesClient;

  /// Overrides cloud uploads (used by tests); defaults to Cognito + S3
  /// when `CloudConfig` is set, and none otherwise.
  final CloudBackend? cloud;

  /// Overrides the clock (used by tests).
  final DateTime Function()? now;

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
    final mediaIo = widget.mediaIo;
    _persistence = Persistence(
      factory: widget.storage != null
          ? Future.value(widget.storage)
          : newDefaultIdbFactory(),
      bus: _bus,
      config: _config,
      // Each event belongs to whoever is signed in when it's recorded.
      currentUser: () => _auth.user?.id,
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
    // Finds the subjects on each new clip once it's recorded.
    _recognizer = SubjectRecognizer(bus: _bus, log: _log, config: _config);
    _bus.publish(AppEvent.appStarted());
    _auth.addListener(_onAuthChanged);
    _rig = CameraRig(
      backend: widget.cameras ?? DeviceCameras(),
      config: _config,
      bus: _bus,
      now: widget.now,
    );
    _auth.init().ignore();
    _roles = RolesService(
      auth: _auth,
      client: widget.rolesClient ?? HttpRolesClient(ApiConfig.baseUrl),
    );
    final cloud =
        widget.cloud ??
        (CloudConfig.enabled
            ? AwsCloudBackend(
                cognito: CognitoCredentials(
                  region: CloudConfig.region,
                  identityPoolId: CloudConfig.identityPoolId,
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
            // And this device's settings, kept per device.
            settings: _persistence,
            // Clips and events fetched from the cloud after sign-in join the
            // local history, like a restore from IndexedDB.
            onRemote: (remote) async => _log.addHistory(
              await _persistence.importRemote(
                events: remote.events,
                clips: remote.clips,
                media: remote.media,
              ),
            ),
          );
    _persistence
      ..attachRig(_rig)
      ..restore(_log).catchError((Object e) {
        debugPrint('Presence: could not restore saved data: $e');
      });
    // A session restored before launch takes over what was recorded
    // signed out, as a sign-in does.
    if (_auth.user case final user?) _claim(user.id);
    _persistence.deviceId.then((id) {
      if (mounted) setState(() => _deviceId = id);
    }, onError: (Object e) => debugPrint('Presence: no device ID: $e'));
    _checkConsent();
    requestPersistentStorage().ignore();
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
    if (given) _rig.load();
  }

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
    _rig.load();
  }

  void _claim(String userId) => _persistence
      .claimAnonymous(userId)
      .catchError(
        (Object e) => debugPrint('Presence: could not claim events: $e'),
      );

  late final AuthService _auth;
  late final RolesService _roles;
  late final MembershipClient _membership =
      widget.membershipClient ?? HttpMembershipClient(ApiConfig.baseUrl);
  CloudSync? _sync;
  String? _signedInAs;

  /// Sign-ins and sign-outs go on the event stream too. A sign-in takes
  /// over the events recorded on this device while signed out.
  void _onAuthChanged() {
    final email = _auth.user?.email;
    if (email == _signedInAs) return;
    final previous = _signedInAs;
    _signedInAs = email;
    if (_auth.user case final user?) _claim(user.id);
    _bus.publish(
      email != null
          ? AppEvent(icon: Icons.login, title: 'Signed in', detail: email)
          : AppEvent(icon: Icons.logout, title: 'Signed out', detail: previous),
    );
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _sync?.dispose();
    _roles.dispose();
    _location.dispose();
    _recognizer.dispose();
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
      child: MaterialApp(
        title: 'Presence',
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
            sync: _sync,
            deviceId: _deviceId,
            location: _location,
            mapTiles: widget.mapTiles,
            battery: widget.battery,
          ),
        },
      ),
    );
  }
}

/// The top-level destinations, as tabs in the app bar.
enum HomeTab {
  camera('Camera', Icons.videocam),
  monitoring('Monitoring', Icons.monitor_heart),
  settings('Settings', Icons.settings);

  const HomeTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The app's one screen: a tab bar in the top right of the app bar flips
/// between the full-screen camera (the start tab), monitoring (the subjects'
/// map, the subjects and the event stream) and the settings (with the
/// device's location map). Swiping sideways flips too, except on
/// Monitoring (its map) and while a finger is on the Settings map.
///
/// Signed out, the camera still shows, but the navigation is hidden: the
/// app bar has only the title and a sign-in button, and the screen stays on
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
    this.sync,
    this.deviceId,
    required this.location,
    this.mapTiles,
    this.battery,
  });

  /// The battery reading over the camera, when not the device's (tests).
  final BatteryReader? battery;

  /// Where this device is (the Settings map, and every event).
  final LocationController location;

  /// The maps' tiles, when not OpenStreetMap's (tests).
  final Widget? mapTiles;

  /// This device's ID (shown in Settings), once it's loaded.
  final String? deviceId;

  /// The signed-in user's roles: events and features need `presence_user`,
  /// the Admin screen `presence_admin`.
  final RolesService roles;

  /// Membership requests: sent from the sign-up sheet, approved on the
  /// Admin screen.
  final MembershipClient membership;

  final EventLog log;
  final CameraRig rig;
  final ConfigController config;
  final AuthService auth;

  /// Cloud uploads, when configured (their status shows in the account
  /// sheet).
  final CloudSync? sync;

  /// Width of each icon tab: Material's 48 dp minimum touch target, which
  /// leaves room for the title on 320 dp phones.
  static const double tabWidth = 48;

  /// How narrow tabs get when the app bar can't fit them at [tabWidth]
  /// (an admin's, with its extra button, on a 320 dp phone).
  static const double minTabWidth = 40;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: HomeTab.values.length,
    vsync: this,
  )..addListener(() => setState(() {}));

  bool get _onCamera => _tabs.index == HomeTab.camera.index;

  /// The battery, shown over the camera; read every minute and on
  /// charging changes.
  late final _battery = BatteryController(widget.battery ?? DeviceBattery());

  /// A finger is on the Settings location map: no swiping to other tabs,
  /// so a drag moves the map.
  bool _mapHeld = false;

  bool get _onMonitoring => _tabs.index == HomeTab.monitoring.index;

  /// The event the Monitoring tab's timeline scrolls to and outlines.
  final _focusedEvent = ValueNotifier<String?>(null);

  /// The Monitoring tab's "Only this device" checkbox: on at launch, and kept
  /// while switching tabs.
  final _thisDeviceOnly = ValueNotifier(true);

  /// Shows [event] in the Monitoring tab's timeline, closing any screen over
  /// the tabs (a subject's).
  void _openEvent(AppEvent event) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    _tabs.animateTo(HomeTab.monitoring.index);
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
    widget.auth.addListener(_onAuthChanged);
    widget.roles.addListener(_onAccessChanged);
  }

  /// Losing access hides the other tabs, so go back to the camera.
  void _onAccessChanged() {
    if (!_hasAccess) _tabs.index = HomeTab.camera.index;
    if (mounted) setState(() {});
  }

  String? _shownError;

  /// Signing out hides the navigation, so go back to the camera. Sign-in
  /// errors pop a message (there's no sign-in screen to show them on).
  void _onAuthChanged() {
    if (!_hasAccess) _tabs.index = HomeTab.camera.index;
    final error = widget.auth.error;
    if (error != null && error != _shownError && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Sign-in failed: $error')));
    }
    _shownError = error;
    setState(() {});
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    widget.roles.removeListener(_onAccessChanged);
    _clipEvents?.cancel();
    _focusedEvent.dispose();
    _thisDeviceOnly.dispose();
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
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$started · saving the next $after s'),
          // A brief pop; for motion clips, the readiness pill carries the
          // cooldown after it. (With an action, snackbars otherwise stay
          // until dismissed.)
          persist: false,
          duration: const Duration(seconds: 4),
          // The events tab is only there with access.
          action: _hasAccess
              ? SnackBarAction(
                  label: 'View',
                  onPressed: () => _tabs.animateTo(HomeTab.monitoring.index),
                )
              : null,
        ),
      );
  }

  /// [HomeScreen.tabWidth], or less (down to [HomeScreen.minTabWidth])
  /// when the tabs, the buttons after them and a sliver of the title don't
  /// fit the screen.
  double _tabWidth(BuildContext context) {
    final buttons =
        (!_dev && widget.roles.isAdmin ? 48 : 0) + (_dev ? 0 : 48) + 4;
    const titleRoom = 12 + 16;
    final fit =
        (MediaQuery.sizeOf(context).width - titleRoom - buttons) /
        HomeTab.values.length;
    return fit.clamp(HomeScreen.minTabWidth, HomeScreen.tabWidth);
  }

  Future<void> _clip() => widget.rig.requestClips(AppEventBusScope.of(context));

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
    return Scaffold(
      // The camera runs edge to edge, under the app bar.
      extendBodyBehindAppBar: true,
      backgroundColor: _onCamera ? Colors.black : scheme.surface,
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          spacing: 8,
          children: [
            Flexible(
              child: Text(
                'Presence',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (_dev) const Flexible(child: DevModeLabel()),
          ],
        ),
        backgroundColor: _onCamera ? Colors.transparent : scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        // Over the camera, a scrim keeps the title and tabs readable.
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
              ),
            AccountButton(auth: widget.auth),
            const SizedBox(width: 4),
          ] else ...[
            SizedBox(
              width: _tabWidth(context) * HomeTab.values.length,
              child: TabBar(
                controller: _tabs,
                dividerHeight: 0,
                indicatorSize: TabBarIndicatorSize.tab,
                labelPadding: EdgeInsets.zero,
                tabs: [
                  for (final tab in HomeTab.values)
                    Tooltip(
                      message: tab.label,
                      child: Tab(
                        icon: Icon(tab.icon, semanticLabel: tab.label),
                      ),
                    ),
                ],
              ),
            ),
            // Admins approve membership requests on their own screen (not
            // in dev mode: there are no accounts).
            if (!_dev && widget.roles.isAdmin)
              IconButton(
                key: const Key('admin'),
                tooltip: 'Admin',
                icon: const Icon(Icons.admin_panel_settings),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AdminScreen(
                      auth: widget.auth,
                      membership: widget.membership,
                    ),
                  ),
                ),
              ),
            // Account (who's signed in, sign out): an action, not a tab.
            if (!_dev) AccountButton(auth: widget.auth, sync: widget.sync),
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
                  thisDeviceOnly: _thisDeviceOnly,
                ),
              ),
              // Full width, with the device's location map.
              SafeArea(
                child: SettingsView(
                  config: widget.config,
                  motionLevel: widget.rig.motionLevel,
                  deviceId: widget.deviceId,
                  health: SystemHealth(roles: widget.roles, sync: widget.sync),
                  location: widget.location,
                  tiles: widget.mapTiles,
                  onMapHeld: (held) => setState(() => _mapHeld = held),
                ),
              ),
            ],
          ),
          // Bottom left, across from Flip and Clip: the battery and whether
          // a clip now would be complete. Signed out, nothing.
          if (_onCamera && _hasAccess)
            _CameraStatus(rig: widget.rig, battery: _battery),
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
                  if (widget.rig.devices.length > 1)
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

/// Whether a clip now would be complete: buffering the "before" history,
/// ready, or counting down while a clip's "after" part is being saved.
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
    // Minutes and seconds for the motion cooldown ("4:59"), seconds below
    // a minute ("45 s").
    final countdown = seconds >= 60
        ? '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}'
        : '$seconds s';
    final (
      Widget leading,
      String label,
      String semantics,
    ) = switch (readiness.state) {
      ClipReadinessState.ready => (
        _Dot(color: Gruvbox.green),
        'Ready',
        'Ready to clip',
      ),
      ClipReadinessState.cooldown => (
        // Red while the motion clip is still saving, then amber.
        _Dot(color: readiness.recording ? Gruvbox.red : Gruvbox.yellow),
        countdown,
        readiness.recording
            ? 'Motion clip saving; motion can clip again in $countdown'
            : 'Motion can clip again in $countdown',
      ),
      ClipReadinessState.unavailable => (
        _Dot(color: scheme.outline),
        'Not ready',
        'Camera not ready',
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

/// The status pills over the camera, bottom left, across from Flip and
/// Clip: the battery, its temperature (Android) and the readiness. In a
/// row, level with the buttons, on wide screens. On phones they stack,
/// starting just above the buttons' row, so however wide they are they
/// never run into Flip and Clip.
class _CameraStatus extends StatelessWidget {
  const _CameraStatus({required this.rig, required this.battery});

  final CameraRig rig;
  final BatteryController battery;

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
      bottom: 16 + padding.bottom + (stacked ? buttonRow : (56 - 40) / 2),
      child: ListenableBuilder(
        listenable: Listenable.merge([rig, battery]),
        builder: (context, _) {
          final reading = battery.reading;
          final pills = [
            if (reading != null) BatteryPill(battery: battery),
            if (reading?.celsius != null)
              BatteryTemperaturePill(battery: battery),
            if (rig.active != null) ReadinessIndicator(rig: rig),
          ];
          return stacked
              ? Column(
                  key: const Key('camera-status'),
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: pills,
                )
              : Row(
                  key: const Key('camera-status'),
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: pills,
                );
        },
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
