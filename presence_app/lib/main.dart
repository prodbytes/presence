import 'dart:async';

import 'package:flutter/material.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory;

import 'auth/account_sheet.dart';
import 'auth/auth_service.dart';
import 'auth/google_auth_service.dart';
import 'camera_feeds.dart';
import 'clips.dart';
import 'config.dart';
import 'cameras/cameras.dart';
import 'events.dart';
import 'settings.dart';
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
  });

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

  @override
  void initState() {
    super.initState();
    // Subscribe before publishing: a broadcast stream drops events that
    // have no listener yet.
    _log = EventLog(_bus.stream);
    final mediaIo = widget.mediaIo;
    _persistence = Persistence(
      factory: widget.storage != null
          ? Future.value(widget.storage)
          : newDefaultIdbFactory(),
      bus: _bus,
      config: _config,
      mediaStore: mediaIo == null
          ? null
          : (store) => IdbMediaStore(store, mediaIo),
    );
    _bus.publish(AppEvent.appStarted());
    _auth = widget.auth ?? GoogleAuthService();
    _auth.addListener(_onAuthChanged);
    _rig = CameraRig(
      backend: widget.cameras ?? DeviceCameras(),
      config: _config,
      bus: _bus,
      now: widget.now,
    )..load();
    _auth.init().ignore();
    _persistence
      ..attachRig(_rig)
      ..restore(_log).catchError((Object e) {
        debugPrint('Presence: could not restore saved data: $e');
      });
    requestPersistentStorage().ignore();
  }

  late final AuthService _auth;
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
    _auth.removeListener(_onAuthChanged);
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
        home: HomeScreen(log: _log, rig: _rig, config: _config, auth: _auth),
      ),
    );
  }
}

/// The top-level destinations, as tabs in the app bar.
enum HomeTab {
  camera('Camera', Icons.videocam),
  events('Events', Icons.notifications),
  settings('Settings', Icons.settings);

  const HomeTab(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// The app's one screen: a tab bar in the top right of the app bar flips
/// between the full-screen camera (the start tab), the event stream and the
/// settings. Swiping sideways flips too.
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
  });

  final EventLog log;
  final CameraRig rig;
  final ConfigController config;
  final AuthService auth;

  /// Width of each icon tab: Material's 48 dp minimum touch target, which
  /// leaves room for the title on 320 dp phones.
  static const double tabWidth = 48;

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

  bool get _signedIn => widget.auth.user != null;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_onAuthChanged);
  }

  String? _shownError;

  /// Signing out hides the navigation, so go back to the camera. Sign-in
  /// errors pop a message (there's no sign-in screen to show them on).
  void _onAuthChanged() {
    if (!_signedIn) _tabs.index = HomeTab.camera.index;
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
    _clipEvents?.cancel();
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
    final started = event.trigger == ClipTrigger.motion
        ? 'Motion detected'
        : 'Clip started';
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
          // The events tab is only there when signed in.
          action: _signedIn
              ? SnackBarAction(
                  label: 'View',
                  onPressed: () => _tabs.animateTo(HomeTab.events.index),
                )
              : null,
        ),
      );
  }

  Future<void> _clip() => widget.rig.requestClips(AppEventBusScope.of(context));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      // The camera runs edge to edge, under the app bar.
      extendBodyBehindAppBar: true,
      backgroundColor: _onCamera ? Colors.black : scheme.surface,
      appBar: AppBar(
        titleSpacing: 12,
        title: Text(
          'Presence',
          style: theme.textTheme.titleLarge?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          ),
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
          if (!_signedIn) ...[
            SignInAction(auth: widget.auth),
            const SizedBox(width: 12),
          ] else ...[
            SizedBox(
              width: HomeScreen.tabWidth * HomeTab.values.length,
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
            // Account (who's signed in, sign out): an action, not a tab.
            AccountButton(auth: widget.auth),
            const SizedBox(width: 4),
          ],
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        // No swiping to the other tabs while they're hidden.
        physics: _signedIn ? null : const NeverScrollableScrollPhysics(),
        children: [
          _KeepAlive(
            child: CameraFeedsView(
              key: const Key('camera-page'),
              rig: widget.rig,
            ),
          ),
          // Readable width on large screens (Material: don't stretch cards
          // edge to edge on desktop).
          SafeArea(
            key: const Key('events-page'),
            child: _ReadableWidth(child: EventTimeline(log: widget.log)),
          ),
          SafeArea(
            child: _ReadableWidth(
              child: SettingsView(
                config: widget.config,
                motionLevel: widget.rig.motionLevel,
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _onCamera
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
                  // Last on the right: whether a clip now would be complete.
                  if (widget.rig.active != null)
                    ReadinessIndicator(rig: widget.rig),
                ],
              ),
            )
          : null,
    );
  }
}

class _ReadableWidth extends StatelessWidget {
  const _ReadableWidth({required this.child});

  static const double maxWidth = 560;

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
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
    return Tooltip(
      message: semantics,
      child: Semantics(
        label: semantics,
        liveRegion: true,
        child: Container(
          key: const Key('readiness'),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              leading,
              ExcludeSemantics(
                child: Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
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
