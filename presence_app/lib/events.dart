import 'package:flutter/material.dart';

import 'camera_feeds.dart';

class AppEvent {
  AppEvent({
    required this.icon,
    required this.title,
    this.detail,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final IconData icon;
  final String title;
  final String? detail;
  final DateTime time;
}

/// Events shown in the Events panel, newest first.
class EventLog extends ChangeNotifier {
  final List<AppEvent> _events = [];

  List<AppEvent> get events => List.unmodifiable(_events);

  void push(AppEvent event) {
    _events.insert(0, event);
    notifyListeners();
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
      itemBuilder: (context, i) => EventCard(event: events[i]),
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
