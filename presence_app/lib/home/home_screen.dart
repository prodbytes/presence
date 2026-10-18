import 'dart:async';

import 'package:flutter/material.dart';

import '../about.dart';
import '../app_log.dart';
import '../battery.dart';
import '../auth/account_sheet.dart';
import '../auth/admin_screen.dart';
import '../auth/auth_service.dart';
import '../auth/delete_account.dart';
import '../auth/rbacr_client.dart';
import '../feedback/feedback_client.dart';
import '../feedback/help_view.dart';
import '../auth/payments_client.dart';
import '../auth/store_billing.dart';
import '../auth/profile_client.dart';
import '../auth/roles_service.dart';
import '../blink_settings.dart';
import '../camera_feeds.dart';
import '../clips.dart';
import '../cloud/cloud_sync.dart';
import '../config.dart';
import '../delete_device.dart';
import '../net_camera_settings.dart';
import '../show_device.dart';
import '../device_events.dart';
import '../events.dart';
import '../home_tabs.dart';
import '../identity/add_device.dart';
import '../identity/join_link.dart';
import '../l10n/l10n.dart';
import '../location/device_location.dart';
import '../log_view.dart';
import '../monitoring.dart';
import '../screen_off.dart';
import '../screen_light.dart';
import '../settings.dart';
import '../system_health.dart';
import '../tab_memory.dart';
import 'camera_buttons.dart';
import 'camera_messages.dart';
import 'camera_mode_menu.dart';
import 'camera_status.dart';
import 'home_app_bar.dart';
import 'home_navigation_bar.dart';

/// The app's one screen: a bottom navigation bar ([HomeNavigationBar])
/// flips between the camera (the start tab), monitoring (the subjects'
/// map, the subjects and the event stream), the settings (with the device's
/// location map), for signed-in members Feedback and Help, for admins who
/// turned it on the log, and for signed-in admins the Admin page
/// (feedback, and a link to rbacr). Only a tap
/// flips: there's no swiping between them, as in most phone apps, so a
/// sideways drag on a map or a list stays there.
///
/// Signed out, the camera still shows, but the navigation is hidden: no
/// navigation bar, the app bar has only a sign-in button, and the screen
/// stays on the camera.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.log,
    required this.rig,
    required this.config,
    required this.auth,
    required this.roles,
    required this.rbacr,
    required this.feedback,
    required this.profiles,
    this.payments,
    this.store,
    this.sync,
    this.deviceId,
    required this.location,
    this.mapTiles,
    this.battery,
    this.join,
    this.onJoinHandled,
    this.tabMemory,
    this.showDevice,
    this.deleteDevice,
    this.deleteAccount,
    this.screenOff,
  });

  /// Turns the screen off in the camera's Unattended mode, while capture
  /// goes on, where the platform can.
  final ScreenOff? screenOff;

  /// Shows or hides a device's events here: from the account sheet's
  /// device list.
  final ShowDevice? showDevice;

  /// Deletes another of the profile's devices, from the account sheet's
  /// device list.
  final DeleteDevice? deleteDevice;

  /// Deletes the signed-in account, from the account sheet's last button.
  final DeleteAccount? deleteAccount;

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

  /// rbacr, as the user: vouchers are redeemed there from the sign-up
  /// sheet.
  final RbacrClient rbacr;

  /// Feedback and Help: members write on the Help tab, admins answer on
  /// the Admin tab.
  final FeedbackClient feedback;

  /// The user's linked Google accounts (account and sign-up sheets).
  final ProfileClient profiles;

  /// The Premium plans' Stripe links: the account sheet's and Monitoring's
  /// upgrade buttons, and the Admin tab's Payments.
  final PaymentsService? payments;

  /// Premium in the App Store or Google Play (iOS, Android).
  final StoreBilling? store;

  final EventLog log;
  final CameraRig rig;
  final ConfigController config;
  final AuthService auth;

  /// Cloud uploads, when configured (their status shows in the account
  /// sheet).
  final CloudSync? sync;

  /// How long a message over the camera stays.
  static const Duration messageFor = Duration(seconds: 4);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  /// The tabs shown, the open one, and the one remembered across refreshes.
  late final HomeTabs _tabs;

  /// The tab open at the last change of [_tabs], to see the Profile tab
  /// open.
  HomeTab? _lastTab;

  /// The Log tab shows for admins (so in DEV too: the anonymous user is a
  /// root there) when Settings' switch is on: by default in DEV only.
  bool get _showLog =>
      widget.roles.isAdmin && widget.config.log.showIn(dev: _dev);

  /// The Admin tab shows for signed-in admins, not in DEV (there are no
  /// accounts).
  bool get _showAdmin => !_dev && widget.roles.isAdmin;

  /// Help is offered to signed-in members, not in DEV (there are no
  /// accounts to write from): a button at the top right of Setup and
  /// Profile ([HomeAppBar.onHelp]), no longer a tab.
  bool get _showHelp => !_dev && _hasAccess;

  /// Settings' section for a kind of network camera (GoPro, Reolink): a
  /// premium profile with cloud sync, not in DEV.
  Widget? _netCameras(NetCameraKind kind) =>
      switch ((widget.sync, widget.roles.profile)) {
        (final sync?, final profile?)
            when !_dev && (widget.roles.isPremium || widget.roles.isAdmin) =>
          NetCameraSettings.of(
            kind: kind,
            sync: sync,
            log: widget.log,
            profileId: profile,
            thisDevice: widget.deviceId,
          ),
        _ => null,
      };

  /// Opens Help as a page of its own, over the tabs.
  void _openHelp() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          key: const Key('help-page'),
          appBar: AppBar(title: Text(context.l10n.navHelpTitle)),
          body: SafeArea(
            child: HelpView(auth: widget.auth, feedback: widget.feedback),
          ),
        ),
      ),
    );
  }

  /// The tabs to show, in [HomeTab] order.
  List<HomeTab> get _shownTabs =>
      HomeTab.shown(log: _showLog, admin: _showAdmin, profile: _showProfile);

  /// The Profile tab shows signed in, not in DEV (there are no accounts).
  bool get _showProfile => !_dev && _signedIn;

  bool get _onCamera => _tabs.current == HomeTab.camera;

  /// The battery, shown over the camera; read every minute and on
  /// charging changes. Made the first time the camera's pills show, so a
  /// screen that never shows them never reads the battery.
  BatteryController get _battery =>
      _batteryOrNull ??= BatteryController(widget.battery ?? DeviceBattery());
  BatteryController? _batteryOrNull;

  /// The Camera tab's view button, All: this device's camera in a grid
  /// with every other device's latest image.
  bool _showAll = false;

  /// The Unattended mode: a black cover hides everything (and the screen
  /// goes off, where it can) while capturing and syncing go on.
  bool _unattended = false;

  /// Unattended, but woken by a tap on the cover: the app shows until
  /// [wakeFor] passes without a touch.
  bool _awake = false;
  Timer? _redark;

  /// How long a woken Unattended screen stays on without a touch.
  static const Duration wakeFor = Duration(seconds: 15);

  void _setUnattended(bool on) {
    _redark?.cancel();
    setState(() {
      _unattended = on;
      _awake = false;
    });
    widget.screenOff?.set(on);
  }

  /// A tap on the cover: the screen comes back, still Unattended.
  void _wake() {
    setState(() => _awake = true);
    widget.screenOff?.set(false);
    _showMessage(
      CameraMessage(
        icon: Icons.brightness_2_outlined,
        label: context.l10n.homeUnattendedWoken,
      ),
    );
    _touched();
  }

  /// A touch while woken: the screen stays on [wakeFor] more.
  void _touched() {
    if (!_unattended || !_awake) return;
    _redark?.cancel();
    _redark = Timer(wakeFor, () {
      if (!mounted || !_unattended) return;
      setState(() => _awake = false);
      widget.screenOff?.set(true);
    });
  }

  /// The mode the menu shows: Normal (this camera), All (the grid),
  /// Unattended (the screen off) or Stopped (the camera off,
  /// [CameraRig.paused], kept in the settings; syncing halted with it).
  CameraMode get _mode => CameraMode.of(
    paused: widget.rig.paused,
    unattended: _unattended,
    showAll: _showAll,
  );

  /// Switches to [mode], picked from the mode menu: leaves the mode shown
  /// (the grid, the screen off or the camera off), then enters [mode].
  void _setMode(CameraMode mode) {
    final was = _mode;
    if (mode == was) return;
    if (_showAll && mode != CameraMode.all) setState(() => _showAll = false);
    if (was == CameraMode.unattended) _setUnattended(false);
    if (was == CameraMode.stopped) widget.rig.setPaused(false);
    switch (mode) {
      case CameraMode.normal:
        break;
      case CameraMode.all:
        setState(() => _showAll = true);
        _askForGrabs();
      case CameraMode.unattended:
        _setUnattended(true);
      case CameraMode.stopped:
        widget.rig.setPaused(true);
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
      widget.log.eventsOf(widget.roles.profile),
      thisDevice: widget.deviceId,
      profileId: widget.roles.profile,
    ).length;
    _showMessage(
      CameraMessage(
        icon: Icons.grid_view,
        label: context.l10n.homeAskedGrabs(devices),
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

  /// Shows [device]'s events ([ShowDeviceEvents]): closes any screen,
  /// dialog or sheet over the tabs, switches to Monitoring and searches
  /// for the device's ID. Only with access (the tab is there).
  void _showDeviceEvents(String device) {
    if (!_hasAccess) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    _tabs.animateTo(HomeTab.monitoring);
    _filters.showDevice(device);
  }

  bool get _signedIn => widget.auth.user != null;

  /// No sign-in configured ([ExecutionMode.dev]): everything but what's
  /// about accounts (sign-in, the account, sign-up and Admin).
  bool get _dev => widget.roles.mode == ExecutionMode.dev;

  /// Signed in as a `presence_user`, or [_dev]: the tabs, the camera's
  /// buttons and (signed in) cloud sync.
  bool get _hasAccess => _dev || (_signedIn && widget.roles.hasAccess);

  void _onTabChanged() {
    _noteTab();
    setState(() {});
  }

  /// The Profile tab opened: its device list asks for the profile's
  /// devices again, so one added since (a streamer) shows.
  void _noteTab() {
    final tab = _tabs.current;
    if (tab == HomeTab.profile && _lastTab != HomeTab.profile) {
      widget.sync?.refreshDevices().ignore();
    }
    _lastTab = tab;
  }

  /// Opens the tab remembered across refreshes, once there's access: the
  /// Profile tab too, whose controller may start on it (no change seen).
  void _restoreTab() {
    _tabs.restore(hasAccess: _hasAccess);
    _noteTab();
  }

  @override
  void initState() {
    super.initState();
    _tabs = HomeTabs(
      vsync: this,
      memory: widget.tabMemory ?? TabMemory(),
      shown: _shownTabs,
      onChanged: _onTabChanged,
    );
    _messages = CameraMessages(showFor: HomeScreen.messageFor)
      ..addListener(_onMessage);
    widget.auth.addListener(_onAuthChanged);
    widget.roles.addListener(_onAccessChanged);
    widget.config.addListener(_onConfigChanged);
    _restoreTab();
  }

  /// Losing access hides the other tabs, so go back to the camera.
  void _onAccessChanged() {
    _tabs.sync(_shownTabs);
    if (!_hasAccess) _tabs.jumpTo(HomeTab.camera);
    _restoreTab();
    if (mounted) setState(() {});
  }

  /// Settings' Log switch adds or removes the Log tab.
  void _onConfigChanged() {
    if (!_tabs.sync(_shownTabs)) return;
    _restoreTab();
    if (mounted) setState(() {});
  }

  String? _shownError;

  /// Signing out hides the navigation, so go back to the camera. Sign-in
  /// errors pop a message (there's no sign-in screen to show them on).
  void _onAuthChanged() {
    // Signing in or out adds or removes the Profile tab.
    _tabs.sync(_shownTabs);
    if (!_hasAccess) _tabs.jumpTo(HomeTab.camera);
    _restoreTab();
    final error = widget.auth.error;
    final problem = widget.auth.problem;
    // The problem too: the same text may come with another meaning.
    final shown = error == null ? null : '${problem?.name}:$error';
    if (shown != null && shown != _shownError && mounted) {
      final text = authErrorText(widget.auth, context.l10n) ?? error!;
      _showMessage(
        CameraMessage(
          icon: Icons.error_outline,
          // A session that ended isn't a failed sign-in: it says so alone.
          label: problem == AuthProblem.sessionEnded
              ? text
              : context.l10n.homeSignInFailed(text),
          error: true,
        ),
        elsewhere: true,
      );
    }
    _shownError = shown;
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
                ? context.l10n.homeJoinedOpen('${widget.deviceId}')
                : context.l10n.homeJoinedAccount(email, '${widget.deviceId}'),
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
    _redark?.cancel();
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
    final l = context.l10n;
    final started = switch (event.trigger) {
      ClipTrigger.motion => l.homeClipMotion,
      ClipTrigger.scheduled => l.homeClipScheduled,
      ClipTrigger.startup => l.homeClipStartup,
      ClipTrigger.manual => l.homeClipManual,
      ClipTrigger.all => l.homeClipAll,
    };
    // After any clip, the Clip button carries the cooldown.
    _showMessage(
      CameraMessage(
        icon: event.icon,
        label: l.homeClipSaving(started, after),
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
    // Nothing shows until the auth API says how the system runs.
    if (widget.roles.state == AccessState.starting) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(key: Key('starting'))),
      );
    }
    final joinStatus = _joinStatus();
    // A tapped device name shows its events, anywhere ([ShowDeviceEvents]).
    final screen = ShowDeviceEvents(
      onShow: _hasAccess ? _showDeviceEvents : null,
      child: _scaffold(context, joinStatus),
    );
    if (!_unattended) return screen;
    // Woken: any touch keeps the screen on a while longer.
    if (_awake) {
      return Listener(onPointerDown: (_) => _touched(), child: screen);
    }
    return Stack(
      children: [
        screen,
        Positioned.fill(child: _ScreenOffCover(onWake: _wake)),
      ],
    );
  }

  Widget _scaffold(BuildContext context, JoinStatus? joinStatus) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      // The camera runs edge to edge, under the app bar, down to the
      // navigation bar.
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
        rbacr: widget.rbacr,
        profiles: widget.profiles,
        sync: widget.sync,
        log: widget.log,
        deviceId: widget.deviceId,
        showDevice: widget.showDevice,
        deleteDevice: widget.deleteDevice,
        deleteAccount: widget.deleteAccount,
        joinFree: widget.store?.joinFree,
        onHelp: _showHelp ? _openHelp : null,
        modeMenu: _onCamera && _hasAccess
            ? ListenableBuilder(
                listenable: widget.rig,
                builder: (context, _) =>
                    CameraModeMenu(mode: _mode, onSelected: _setMode),
              )
            : null,
      ),
      body: Stack(
        children: [
          TabBarView(
            controller: _tabs.controller,
            // Only the navigation bar flips: a sideways drag stays on the
            // page (its maps and lists).
            physics: const NeverScrollableScrollPhysics(),
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
                  onSync: switch (widget.sync) {
                    final sync? => sync.syncAll,
                    null => null,
                  },
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
                  logTabDefault: widget.roles.isAdmin ? _dev : null,
                  liveSync: widget.sync?.live?.enabled ?? false,
                  blink: switch ((widget.sync, widget.roles.profile)) {
                    (final sync?, final profile?)
                        when !_dev &&
                            (widget.roles.isPremium || widget.roles.isAdmin) =>
                      BlinkSettings.of(
                        sync: sync,
                        log: widget.log,
                        profileId: profile,
                        thisDevice: widget.deviceId,
                      ),
                    _ => null,
                  },
                  gopro: _netCameras(NetCameraKind.gopro),
                  reolink: _netCameras(NetCameraKind.reolink),
                  liveAdmin: widget.roles.isAdmin,
                  liveFree:
                      widget.roles.hasAccess &&
                      !widget.roles.isAdmin &&
                      !widget.roles.isPremium,
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
              // Feedback, and a link to rbacr (vouchers, maintenance): a
              // page like the others, with no back button of its own.
              if (_tabs.shows(HomeTab.admin))
                SafeArea(
                  child: AdminView(
                    auth: widget.auth,
                    feedback: widget.feedback,
                    payments: widget.payments,
                  ),
                ),
              // Who's signed in, the profile's devices, sign-out and about:
              // the account sheet, as a page of the tabs.
              if (_tabs.shows(HomeTab.profile))
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: AccountSheet(
                          key: const Key('account-page'),
                          auth: widget.auth,
                          sync: widget.sync,
                          roles: widget.roles,
                          profiles: widget.profiles,
                          payments: widget.payments,
                          store: widget.store,
                          log: widget.log,
                          deviceId: widget.deviceId,
                          showDevice: widget.showDevice,
                          deleteDevice: widget.deleteDevice,
                          deleteAccount: widget.deleteAccount,
                        ),
                      ),
                    ),
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
          // Signed out, nothing else is at the bottom: the Privacy Policy
          // and Terms of Service (with access, they're in the Profile tab).
          if (_onCamera && !_hasAccess && !_signedIn)
            const SignedOutLegalLinks(),
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
          // Night mode: the screen lights the scene while a clip records.
          ScreenLightOverlay(on: widget.rig.screenLight),
        ],
      ),
      // The tabs, with access; signed out, the camera shows alone.
      bottomNavigationBar: _hasAccess
          ? HomeNavigationBar(tabs: _tabs, user: widget.auth.user)
          : null,
      // Signed out, the camera shows with no buttons at all.
      floatingActionButton: _onCamera && _hasAccess
          ? CameraButtons(rig: widget.rig, onClip: _clip)
          : null,
    );
  }
}

/// Covers the app in black in the Unattended mode, with a faint hint; a
/// tap anywhere wakes the screen, still Unattended. Where the screen goes
/// off ([HomeScreen.screenOff]), seen only before the system's timeout
/// turns it off, or after the power button wakes it.
class _ScreenOffCover extends StatelessWidget {
  const _ScreenOffCover({required this.onWake});

  final VoidCallback onWake;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('screen-off-cover'),
      behavior: HitTestBehavior.opaque,
      onTap: onWake,
      // Material, so the hint has a text style outside the Scaffold.
      child: Material(
        color: Colors.black,
        child: Center(
          child: Text(
            context.l10n.homeScreenOffHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF3C3836), fontSize: 14),
          ),
        ),
      ),
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
