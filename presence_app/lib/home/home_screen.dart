import 'dart:async';

import 'package:flutter/material.dart';

import '../app_log.dart';
import '../battery.dart';
import '../auth/admin_screen.dart';
import '../auth/auth_service.dart';
import '../auth/membership_client.dart';
import '../auth/profile_client.dart';
import '../auth/roles_service.dart';
import '../camera_feeds.dart';
import '../clips.dart';
import '../cloud/cloud_sync.dart';
import '../config.dart';
import '../delete_device.dart';
import '../events.dart';
import '../home_tabs.dart';
import '../identity/add_device.dart';
import '../identity/join_link.dart';
import '../location/device_location.dart';
import '../log_view.dart';
import '../monitoring.dart';
import '../settings.dart';
import '../system_health.dart';
import '../tab_memory.dart';
import 'camera_buttons.dart';
import 'camera_messages.dart';
import 'camera_status.dart';
import 'home_app_bar.dart';

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
    this.deleteDevice,
  });

  /// Deletes another of the profile's devices: from the account sheet's
  /// device list, after a confirmation.
  final DeleteDevice? deleteDevice;

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
  /// The tabs shown, the open one, and the one remembered across refreshes.
  late final HomeTabs _tabs;

  /// The Log tab shows for admins (so in DEV too: the anonymous user is a
  /// root there) when Settings' switch is on: by default in DEV only.
  bool get _showLog =>
      widget.roles.isAdmin && widget.config.log.showIn(dev: _dev);

  /// The Admin tab shows for signed-in admins, not in DEV (there are no
  /// accounts).
  bool get _showAdmin => !_dev && widget.roles.isAdmin;

  /// The tabs to show, in [HomeTab] order.
  List<HomeTab> get _shownTabs =>
      HomeTab.shown(log: _showLog, admin: _showAdmin);

  bool get _onCamera => _tabs.current == HomeTab.camera;

  /// The battery, shown over the camera; read every minute and on
  /// charging changes. Made the first time the camera's pills show, so a
  /// screen that never shows them never reads the battery.
  BatteryController get _battery =>
      _batteryOrNull ??= BatteryController(widget.battery ?? DeviceBattery());
  BatteryController? _batteryOrNull;

  /// A finger is on the Settings location map: no swiping to other tabs,
  /// so a drag moves the map.
  bool _mapHeld = false;

  bool get _onMonitoring => _tabs.current == HomeTab.monitoring;

  /// The Camera tab's view button, All: this device's camera in a grid
  /// with every other device's latest image.
  bool _showAll = false;

  /// What the view button shows: One (this camera), All (the grid) or None
  /// (the camera off: [CameraRig.paused], kept in the settings).
  CameraViewMode get _viewMode =>
      CameraViewMode.of(paused: widget.rig.paused, showAll: _showAll);

  /// One → All → None → One.
  void _nextViewMode() {
    switch (_viewMode) {
      case CameraViewMode.one:
        setState(() => _showAll = true);
        _askForGrabs();
      case CameraViewMode.all:
        setState(() => _showAll = false);
        widget.rig.setPaused(true);
      case CameraViewMode.none:
        widget.rig.setPaused(false);
    }
  }

  /// How long the All grid's cells show that a fresh grab was asked for
  /// ([CameraFeedsView.refreshingSince]) before giving up on one.
  static const Duration refreshingFor = Duration(seconds: 90);

  /// When this device last asked the others for a fresh grab, while the
  /// grid waits for them ([refreshingFor]).
  DateTime? _refreshingSince;
  Timer? _refreshingTimer;

  /// Opening the All grid asks every device of the profile for a fresh
  /// grab (a Capture all request, [CameraRig.askAll]: at most one a
  /// minute), so the grid shows what they see now; signed in with cloud
  /// sync only, which carries it (live sync too, within a second).
  void _askForGrabs() {
    if (!_hasAccess || widget.sync == null) return;
    final request = widget.rig.askAll(AppEventBusScope.of(context));
    if (request != null) _asked(request);
  }

  /// Says that [request] went out, and marks the grid's cells as waiting
  /// for a newer grab.
  void _asked(AppEvent request) {
    final devices = latestByDevice(
      widget.log.events,
      thisDevice: widget.deviceId,
      profileId: widget.roles.profile,
    ).length;
    _showMessage(
      CameraMessage(
        icon: Icons.grid_view,
        label: switch (devices) {
          0 => 'Asked every device for a fresh grab',
          1 => 'Asked 1 device for a fresh grab…',
          _ => 'Asked $devices devices for a fresh grab…',
        },
      ),
    );
    _refreshingTimer?.cancel();
    _refreshingTimer = Timer(refreshingFor, () {
      if (mounted) setState(() => _refreshingSince = null);
    });
    setState(() => _refreshingSince = request.time);
  }

  /// What the Monitoring tab shows, kept while switching tabs: the device
  /// picked by tapping an event's device (none at launch: every device's),
  /// the "Show system events" toggle (on in DEV, off otherwise: only
  /// grabs), the search (blank at launch) and the event to open. Made on
  /// first use, once the execution mode is known.
  EventFilters get _filters =>
      _filtersOrNull ??= EventFilters(showSystemEvents: _dev);
  EventFilters? _filtersOrNull;

  /// Shows [event] in the Monitoring tab's timeline, closing any screen over
  /// the tabs (a subject's).
  void _openEvent(AppEvent event) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    _tabs.animateTo(HomeTab.monitoring);
    // A one-shot request: handled once, by the timeline shown now or the
    // next one built.
    _filters.focus(event.id);
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
    _tabs = HomeTabs(
      vsync: this,
      memory: widget.tabMemory ?? TabMemory(),
      shown: _shownTabs,
      onChanged: () => setState(() {}),
    );
    _messages = CameraMessages(showFor: HomeScreen.messageFor)
      ..addListener(_onMessage);
    widget.auth.addListener(_onAuthChanged);
    widget.roles.addListener(_onAccessChanged);
    widget.config.addListener(_onConfigChanged);
    _tabs.restore(hasAccess: _hasAccess);
  }

  /// Losing access hides the other tabs, so go back to the camera.
  void _onAccessChanged() {
    _tabs.sync(_shownTabs);
    if (!_hasAccess) _tabs.jumpTo(HomeTab.camera);
    _tabs.restore(hasAccess: _hasAccess);
    if (mounted) setState(() {});
  }

  /// Settings' Log switch adds or removes the Log tab.
  void _onConfigChanged() {
    if (!_tabs.sync(_shownTabs)) return;
    _tabs.restore(hasAccess: _hasAccess);
    if (mounted) setState(() {});
  }

  String? _shownError;

  /// Signing out hides the navigation, so go back to the camera. Sign-in
  /// errors pop a message (there's no sign-in screen to show them on).
  void _onAuthChanged() {
    if (!_hasAccess) _tabs.jumpTo(HomeTab.camera);
    _tabs.restore(hasAccess: _hasAccess);
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

  /// The message over the camera, a pill bottom left, for
  /// [HomeScreen.messageFor].
  late final CameraMessages _messages;

  /// Shows [message]: on the Camera tab as a pill bottom left, so nothing
  /// over the camera moves or is covered; a newer message replaces it. On
  /// the other tabs, a snackbar if [elsewhere], else nothing.
  void _showMessage(CameraMessage message, {bool elsewhere = false}) {
    if (!_onCamera) {
      if (elsewhere) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message.label)));
      }
      return;
    }
    _messages.show(message);
  }

  /// A message shows or goes.
  void _onMessage() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.auth.removeListener(_onAuthChanged);
    widget.roles.removeListener(_onAccessChanged);
    widget.config.removeListener(_onConfigChanged);
    _clipEvents?.cancel();
    _messages.dispose();
    _refreshingTimer?.cancel();
    _filtersOrNull?.dispose();
    _batteryOrNull?.dispose();
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
    // After any clip, the Clip button carries the cooldown.
    _showMessage(
      CameraMessage(
        icon: event.icon,
        label: '$started · saving the next $after s',
        opensEvents: true,
      ),
    );
  }

  /// The Clip button: this camera's clip; with the All grid showing, a
  /// Capture all request too, which cloud sync takes to the profile's other
  /// devices so each takes a clip ([CameraRig.answerCaptureAll]).
  Future<void> _clip() {
    final bus = AppEventBusScope.of(context);
    if (!(_showAll && _hasAccess)) return widget.rig.requestClips(bus);
    // A press always asks (opening the grid's minute doesn't hold it back),
    // unless a request went out within the last few seconds (a double tap,
    // or the grid just opened).
    if (widget.rig.askAll(bus, pressed: true) case final request?) {
      _asked(request);
    }
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
      appBar: HomeAppBar(
        tabs: _tabs,
        onCamera: _onCamera,
        dev: _dev,
        hasAccess: _hasAccess,
        signedIn: _signedIn,
        auth: widget.auth,
        roles: widget.roles,
        membership: widget.membership,
        profiles: widget.profiles,
        sync: widget.sync,
        log: widget.log,
        deviceId: widget.deviceId,
        deleteDevice: widget.deleteDevice,
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabs.controller,
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
                  refreshingSince: _showAll ? _refreshingSince : null,
                  live: widget.sync?.live,
                  active: _onCamera,
                ),
              ),
              SafeArea(
                child: MonitoringView(
                  log: widget.log,
                  config: widget.config,
                  tiles: widget.mapTiles,
                  onOpenEvent: _openEvent,
                  deviceId: widget.deviceId,
                  profileId: widget.roles.profile,
                  filters: _filters,
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
                  liveSync: widget.sync?.live?.enabled ?? false,
                  liveAdmin: widget.roles.isAdmin,
                ),
              ),
              if (_tabs.shows(HomeTab.log))
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
              if (_tabs.shows(HomeTab.admin))
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
          // the battery, and after it the latest message. Signed out, only
          // the message.
          if (_onCamera && (_hasAccess || _messages.current != null))
            CameraStatus(
              rig: widget.rig,
              battery: _battery,
              full: _hasAccess,
              // Tapping it opens the health panel (Log), or for non-admins
              // the health line (Settings).
              roles: widget.roles,
              sync: widget.sync,
              onHealthTap: () => _tabs.animateTo(
                _tabs.shows(HomeTab.log) ? HomeTab.log : HomeTab.settings,
              ),
              message: switch (_messages.current) {
                final m? => CameraMessagePill(
                  message: m,
                  // The events tab is only there with access.
                  onView: m.opensEvents && _hasAccess
                      ? () => _tabs.animateTo(HomeTab.monitoring)
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
          ? CameraButtons(
              rig: widget.rig,
              showAll: _showAll,
              onNextViewMode: _nextViewMode,
              onClip: _clip,
            )
          : null,
    );
  }
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
