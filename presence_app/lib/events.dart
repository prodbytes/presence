import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'camera_feeds.dart';

/// Something that happened, shown in the Events timeline and saved to
/// storage.
class AppEvent {
  AppEvent({
    required this.icon,
    required this.title,
    this.detail,
    this.type = genericType,
    this.cameraId,
    DateTime? time,
    String? id,
  }) : time = time ?? DateTime.now(),
       id = id ?? newId();

  /// The app launched.
  AppEvent.appStarted({DateTime? time, String? id})
    : this(
        icon: Icons.power_settings_new,
        title: 'Application started',
        type: appStartedType,
        time: time,
        id: id,
      );

  static const String genericType = 'generic';
  static const String appStartedType = 'app_started';

  final String id;

  /// What kind of event this is; decides how it's restored from storage.
  final String type;

  final IconData icon;
  final String title;
  final String? detail;
  final DateTime time;

  /// The camera the event came from, if any.
  final String? cameraId;

  /// The stored form of this event. Subclasses keep their extra data in
  /// their own records (a clip's recordings live in the clips store).
  Map<String, Object?> toRecord() => {
    'id': id,
    'type': type,
    'title': title,
    'detail': detail,
    'time': time.millisecondsSinceEpoch,
    'cameraId': cameraId,
  };

  /// Rebuilds a stored event of a plain type. Returns null for types that
  /// need more than the event record (like clips).
  static AppEvent? fromRecord(Map<String, Object?> record) {
    final type = record['type'] as String? ?? genericType;
    final time = DateTime.fromMillisecondsSinceEpoch(record['time']! as int);
    final id = record['id']! as String;
    return switch (type) {
      appStartedType => AppEvent.appStarted(time: time, id: id),
      genericType => AppEvent(
        // Icons can't be stored (tree shaking needs const icons), so plain
        // events come back with a generic one.
        icon: Icons.notifications_none,
        title: record['title'] as String? ?? 'Event',
        detail: record['detail'] as String?,
        cameraId: record['cameraId'] as String?,
        time: time,
        id: id,
      ),
      _ => null,
    };
  }

  /// Unique enough for one person's event history: time-ordered, plus
  /// randomness so events in the same microsecond don't collide.
  static String newId() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    // Not `1 << 32`: on web, shifts are 32-bit and that evaluates to 0.
    final noise = _random.nextInt(0xFFFFFFFF).toRadixString(36).padLeft(7, '0');
    return '$now-$noise';
  }

  static final _random = Random();

  /// The card shown for this event in the timeline. Event types with richer
  /// content override this.
  Widget buildCard(BuildContext context) => EventCard(event: this);
}

/// App-wide event bus: a plain broadcast stream. Anything can publish, and
/// any number of listeners can subscribe. It keeps no history; late
/// subscribers only see events published after they subscribe.
class AppEventBus {
  final _controller = StreamController<AppEvent>.broadcast();

  Stream<AppEvent> get stream => _controller.stream;

  void publish(AppEvent event) => _controller.add(event);

  Future<void> close() => _controller.close();
}

/// Makes the [AppEventBus] reachable from any widget below it.
class AppEventBusScope extends InheritedWidget {
  const AppEventBusScope({super.key, required this.bus, required super.child});

  final AppEventBus bus;

  static AppEventBus of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppEventBusScope>();
    assert(scope != null, 'No AppEventBusScope above this context.');
    return scope!.bus;
  }

  @override
  bool updateShouldNotify(AppEventBusScope oldWidget) => bus != oldWidget.bus;
}

/// History of bus events for the Events panel, newest first.
class EventLog extends ChangeNotifier {
  EventLog(Stream<AppEvent> events) {
    _subscription = events.listen(_add);
  }

  late final StreamSubscription<AppEvent> _subscription;
  final List<AppEvent> _events = [];

  List<AppEvent> get events => List.unmodifiable(_events);

  void _add(AppEvent event) {
    _events.insert(0, event);
    notifyListeners();
  }

  /// Adds events restored from storage, keeping the timeline newest first.
  /// Events already in the log (published since launch) are kept.
  void addHistory(Iterable<AppEvent> history) {
    final known = {for (final e in _events) e.id};
    _events
      ..addAll(history.where((e) => !known.contains(e.id)))
      ..sort((a, b) => b.time.compareTo(a.time));
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

/// Scrollable timeline of events, newest at the top.
class EventTimeline extends StatefulWidget {
  const EventTimeline({super.key, required this.log});

  final EventLog log;

  @override
  State<EventTimeline> createState() => _EventTimelineState();
}

class _EventTimelineState extends State<EventTimeline> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.log.addListener(_onEvent);
  }

  @override
  void didUpdateWidget(EventTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.log != widget.log) {
      oldWidget.log.removeListener(_onEvent);
      widget.log.addListener(_onEvent);
    }
  }

  @override
  void dispose() {
    widget.log.removeListener(_onEvent);
    _scroll.dispose();
    super.dispose();
  }

  void _onEvent() {
    setState(() {});
    // Bring the newest event into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final events = widget.log.events;
    if (events.isEmpty) {
      return const FeedMessage(
        icon: Icons.notifications_none,
        message: 'No events',
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.all(12),
      itemCount: events.length,
      separatorBuilder: (context, i) => const SizedBox(height: 8),
      itemBuilder: (context, i) => events[i].buildCard(context),
    );
  }
}

class EventCard extends StatelessWidget {
  const EventCard({super.key, required this.event});

  final AppEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final detail = event.detail;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(event.icon, size: 20, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event.title, style: theme.textTheme.titleSmall),
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatEventTime(event.time),
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatEventTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
