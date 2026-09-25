import 'package:flutter/material.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory;

import 'camera_feeds.dart';
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
  const PresenceApp({super.key, this.cameras, this.storage, this.mediaIo});

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
  final _settings = ClipSettings();
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
      settings: _settings,
      mediaStore: mediaIo == null
          ? null
          : (store) => IdbMediaStore(store, mediaIo),
    );
    _bus.publish(AppEvent.appStarted());
    _rig = CameraRig(
      backend: widget.cameras ?? DeviceCameras(),
      settings: _settings,
    )..load();
    _persistence
      ..attachRig(_rig)
      ..restore(_log).catchError((Object e) {
        debugPrint('Presence: could not restore saved data: $e');
      });
    requestPersistentStorage().ignore();
  }

  @override
  void dispose() {
    _persistence.dispose();
    _rig.dispose();
    _log.dispose();
    _bus.close();
    _settings.dispose();
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
        home: HomeScreen(log: _log, rig: _rig, settings: _settings),
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
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.log,
    required this.rig,
    required this.settings,
  });

  final EventLog log;
  final CameraRig rig;
  final ClipSettings settings;

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

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _clip() async {
    await widget.rig.requestClips(AppEventBusScope.of(context));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Clip requested'),
          action: SnackBarAction(
            label: 'View',
            onPressed: () => _tabs.animateTo(HomeTab.events.index),
          ),
        ),
      );
  }

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
                    child: Tab(icon: Icon(tab.icon, semanticLabel: tab.label)),
                  ),
              ],
            ),
          ),
          // Not a destination yet, so not a tab: shown, but disabled.
          const IconButton(
            tooltip: 'Login (coming soon)',
            icon: Icon(Icons.person),
            onPressed: null,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
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
              child: SettingsView(settings: widget.settings),
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
