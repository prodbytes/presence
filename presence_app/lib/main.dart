import 'package:flutter/material.dart';
import 'package:idb_shim/idb_shim.dart' show IdbFactory;
import 'package:url_launcher/link.dart';

import 'camera_feeds.dart';
import 'cameras/cameras.dart';
import 'events.dart';
import 'settings.dart';
import 'storage/media_platform.dart';
import 'storage/persistence.dart';
import 'theme.dart';

void main() {
  runApp(const PresenceApp());
}

class PresenceApp extends StatefulWidget {
  const PresenceApp({super.key, this.openCameras, this.storage, this.mediaIo});

  /// Overrides camera access (used by tests); defaults to all device cameras.
  final CameraOpener? openCameras;

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
    _persistence = Persistence(
      factory: widget.storage ?? newDefaultIdbFactory(),
      bus: _bus,
      settings: _settings,
      io: widget.mediaIo ?? const MediaIo(),
    );
    _bus.publish(AppEvent.appStarted());
    _rig = CameraRig(
      open: widget.openCameras ?? openDeviceCameras,
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
        home: MonitorPage(log: _log, rig: _rig, settings: _settings),
      ),
    );
  }
}

/// Main screen: camera feeds fill the left, events sit in a fixed-width
/// panel on the right. Settings open as an end drawer.
class MonitorPage extends StatelessWidget {
  const MonitorPage({
    super.key,
    required this.log,
    required this.rig,
    required this.settings,
  });

  final EventLog log;
  final CameraRig rig;
  final ClipSettings settings;

  static const double eventsPanelWidth = 360;
  static const double gap = 12;

  @override
  Widget build(BuildContext context) {
    const gap = MonitorPage.gap;
    return Scaffold(
      endDrawer: SettingsPane(settings: settings),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(gap),
          child: Row(
            children: [
              Expanded(child: CameraFeedsPanel(rig: rig)),
              const SizedBox(width: gap),
              SizedBox(
                width: MonitorPage.eventsPanelWidth,
                child: EventsPanel(log: log),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CameraFeedsPanel extends StatelessWidget {
  const CameraFeedsPanel({super.key, required this.rig});

  final CameraRig rig;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      key: const Key('camera-feeds-panel'),
      title: const AppTitleLink(),
      actions: [
        ListenableBuilder(
          listenable: rig,
          builder: (context, _) => IconButton.filledTonal(
            tooltip: 'Clip',
            icon: const Icon(Icons.photo_camera),
            onPressed: rig.canClip
                ? () => rig.requestClips(AppEventBusScope.of(context))
                : null,
          ),
        ),
      ],
      child: CameraFeedsView(rig: rig),
    );
  }
}

class EventsPanel extends StatelessWidget {
  const EventsPanel({super.key, required this.log});

  final EventLog log;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      key: const Key('events-panel'),
      title: const _PanelTitle('Events'),
      actions: [
        IconButton.filledTonal(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings),
          onPressed: () => Scaffold.of(context).openEndDrawer(),
        ),
        IconButton.filledTonal(
          tooltip: 'Login',
          icon: const Icon(Icons.person),
          onPressed: () {},
        ),
      ],
      child: EventTimeline(log: log),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.title,
    required this.child,
    this.actions = const [],
  });

  final Widget title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: SizedBox(
              height: 40,
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: title),
                  ),
                  ...actions,
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.titleMedium);
  }
}

/// The app name, linking to the project site. On web this is a real anchor,
/// so middle-click and "open in new tab" work.
class AppTitleLink extends StatelessWidget {
  const AppTitleLink({super.key});

  static const String name = 'Presence';
  static final Uri url = Uri.parse('https://presence.nu01.com');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Link(
      uri: url,
      target: LinkTarget.blank,
      builder: (context, followLink) => InkWell(
        onTap: followLink,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            name,
            style: theme.textTheme.titleLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
