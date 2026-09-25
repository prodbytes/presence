import 'package:flutter/material.dart';
import 'package:url_launcher/link.dart';

import 'camera_feeds.dart';
import 'events.dart';
import 'theme.dart';

void main() {
  runApp(const PresenceApp());
}

class PresenceApp extends StatefulWidget {
  const PresenceApp({super.key, this.loadCameras});

  /// Overrides camera discovery (used by tests); defaults to all device cameras.
  final CameraLoader? loadCameras;

  @override
  State<PresenceApp> createState() => _PresenceAppState();
}

class _PresenceAppState extends State<PresenceApp> {
  // Owned above MaterialApp so every route can publish to the bus, and so
  // the history outlives any single screen.
  final _bus = AppEventBus();
  late final EventLog _log;

  @override
  void initState() {
    super.initState();
    // Subscribe before publishing: a broadcast stream drops events that
    // have no listener yet.
    _log = EventLog(_bus.stream);
    _bus.publish(
      AppEvent(icon: Icons.power_settings_new, title: 'Application started'),
    );
  }

  @override
  void dispose() {
    _log.dispose();
    _bus.close();
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
        home: MonitorPage(log: _log, loadCameras: widget.loadCameras),
      ),
    );
  }
}

/// Main screen: camera feeds fill the left, events sit in a fixed-width
/// panel on the right.
class MonitorPage extends StatelessWidget {
  const MonitorPage({super.key, required this.log, this.loadCameras});

  final EventLog log;
  final CameraLoader? loadCameras;

  static const double eventsPanelWidth = 360;
  static const double gap = 12;

  @override
  Widget build(BuildContext context) {
    const gap = MonitorPage.gap;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(gap),
          child: Row(
            children: [
              Expanded(child: CameraFeedsPanel(loadCameras: loadCameras)),
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
  const CameraFeedsPanel({super.key, this.loadCameras});

  final CameraLoader? loadCameras;

  @override
  Widget build(BuildContext context) {
    final loader = loadCameras;
    return _Panel(
      key: const Key('camera-feeds-panel'),
      title: const AppTitleLink(),
      actions: [
        IconButton.filledTonal(
          tooltip: 'Clip',
          icon: const Icon(Icons.photo_camera),
          onPressed: () {},
        ),
      ],
      child: loader == null
          ? const CameraFeedsView()
          : CameraFeedsView(loadCameras: loader),
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
          onPressed: () {},
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
