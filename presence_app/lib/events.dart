import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'camera_feeds.dart';
import 'clips.dart';
import 'location/device_location.dart';

/// Something that happened, shown in the Events timeline and saved to
/// storage.
class AppEvent {
  AppEvent({
    required this.icon,
    required this.title,
    this.detail,
    this.type = genericType,
    this.cameraId,
    this.deviceId,
    this.userId,
    this.location,
    DateTime? time,
    String? id,
  }) : time = time ?? DateTime.now(),
       id = id ?? newId();

  /// The app launched.
  AppEvent.appStarted({
    DateTime? time,
    String? id,
    String? deviceId,
    String? userId,
  }) : this(
         icon: Icons.power_settings_new,
         title: 'Application started',
         type: appStartedType,
         time: time,
         id: id,
         deviceId: deviceId,
         userId: userId,
       );

  static const String genericType = 'generic';
  static const String appStartedType = 'app_started';

  /// The [userId] of events recorded while nobody was signed in. The next
  /// user to sign in on the device takes them over
  /// (`Persistence.claimAnonymous`).
  static const String anonymousUserId = 'anonymous';

  final String id;

  /// What kind of event this is; decides how it's restored from storage.
  final String type;

  final IconData icon;
  final String title;
  final String? detail;
  final DateTime time;

  /// The camera the event came from, if any.
  final String? cameraId;

  /// The device that recorded the event (`DeviceId`, such as
  /// `automatic_paranoid_gadget`). Set when it's saved.
  String? deviceId;

  /// Who the event belongs to: the signed-in user's ID when it was
  /// recorded, or [anonymousUserId]. Set when it's saved, and changed once,
  /// from anonymous, when a user signs in on the device.
  String? userId;

  /// Where the device was when the event was published: its own position,
  /// or the one set on the Device screen's map. Null while it's unknown.
  DeviceLocation? location;

  /// The stored form of this event. Subclasses keep their extra data in
  /// their own records (a clip's recordings live in the clips store).
  Map<String, Object?> toRecord() => {
    'id': id,
    'type': type,
    'title': title,
    'detail': detail,
    'time': time.millisecondsSinceEpoch,
    'cameraId': cameraId,
    'deviceId': deviceId,
    'userId': userId,
    'location': location?.toJson(),
  };

  /// Rebuilds a stored event of a plain type. Returns null for types that
  /// need more than the event record (like clips).
  static AppEvent? fromRecord(Map<String, Object?> record) {
    final type = record['type'] as String? ?? genericType;
    final time = DateTime.fromMillisecondsSinceEpoch(record['time']! as int);
    final id = record['id']! as String;
    final deviceId = record['deviceId'] as String?;
    final userId = ownerOf(record);
    final event = switch (type) {
      appStartedType => AppEvent.appStarted(
        time: time,
        id: id,
        deviceId: deviceId,
        userId: userId,
      ),
      genericType => AppEvent(
        // Icons can't be stored (tree shaking needs const icons), so plain
        // events come back with a generic one.
        icon: Icons.notifications_none,
        title: record['title'] as String? ?? 'Event',
        detail: record['detail'] as String?,
        cameraId: record['cameraId'] as String?,
        deviceId: deviceId,
        userId: userId,
        time: time,
        id: id,
      ),
      _ => null,
    };
    return event?..location = DeviceLocation.fromJson(record['location']);
  }

  /// The user a stored event belongs to. Events saved before events had
  /// owners count as anonymous.
  static String ownerOf(Map<String, Object?> record) =>
      record['userId'] as String? ?? anonymousUserId;

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
  const EventTimeline({
    super.key,
    required this.log,
    this.focus,
    this.deviceId,
    this.thisDeviceOnly,
    this.showSystemEvents,
    this.padding = const EdgeInsets.all(12),
  });

  final EventLog log;

  /// Around the cards, inside the scrolling list.
  final EdgeInsets padding;

  /// This device's ID. Once it's known, the timeline shows only this
  /// device's events unless [thisDeviceOnly] is unchecked.
  final String? deviceId;

  /// Whether only this device's events show (the [ThisDeviceOnly] checkbox
  /// at the top of the Monitoring tab). Kept by the caller, so it survives
  /// the tab being rebuilt; defaults to an own one, on.
  final ValueNotifier<bool>? thisDeviceOnly;

  /// Whether system events show (the [ShowSystemEvents] chip): on, every
  /// event, such as "Application started" and sign-ins; off, only grabs
  /// ([ClipRequested]: a clip, by hand, on motion, at start or on a
  /// schedule). Kept by the caller; defaults to an own one, on.
  final ValueNotifier<bool>? showSystemEvents;

  /// Whether [event] is a grab, shown even with system events hidden.
  static bool isGrab(AppEvent event) => event is ClipRequested;

  /// The ID of an event to scroll to and outline (an event opened from
  /// elsewhere, such as a subject's map). Setting it again, even to the
  /// same ID, scrolls to it again.
  final ValueListenable<String?>? focus;

  /// How long an event opened through [focus] stays outlined.
  static const Duration highlightFor = Duration(seconds: 4);

  @override
  State<EventTimeline> createState() => _EventTimelineState();
}

class _EventTimelineState extends State<EventTimeline> {
  final _scroll = ScrollController();

  ValueNotifier<bool>? _ownFilter;
  ValueNotifier<bool> get _filter =>
      widget.thisDeviceOnly ?? (_ownFilter ??= ValueNotifier(true));

  ValueNotifier<bool>? _ownSystem;
  ValueNotifier<bool> get _system =>
      widget.showSystemEvents ?? (_ownSystem ??= ValueNotifier(true));

  /// The events of the devices shown: this device's while [_filter] is on.
  /// Events not saved yet have no device ID; they're this device's.
  List<AppEvent> get _ofDevices {
    final events = widget.log.events;
    final device = widget.deviceId;
    if (device == null || !_filter.value) return events;
    return [
      for (final e in events)
        if (e.deviceId == null || e.deviceId == device) e,
    ];
  }

  /// The events shown: [_ofDevices], only the grabs while [_system] is off.
  List<AppEvent> get _shown {
    final events = _ofDevices;
    if (_system.value) return events;
    return events.where(EventTimeline.isGrab).toList();
  }

  /// Each card's key, to find it once it's built.
  final _cards = <String, GlobalKey>{};

  /// The outlined event, while [EventTimeline.highlightFor] lasts.
  String? _highlighted;
  Timer? _unhighlight;

  @override
  void initState() {
    super.initState();
    widget.log.addListener(_onEvent);
    widget.focus?.addListener(_onFocus);
    _filter.addListener(_onFilter);
    _system.addListener(_onFilter);
    // The tab may be built only once the event was asked for.
    if (widget.focus?.value != null) _onFocus();
  }

  @override
  void didUpdateWidget(EventTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.log != widget.log) {
      oldWidget.log.removeListener(_onEvent);
      widget.log.addListener(_onEvent);
    }
    if (oldWidget.focus != widget.focus) {
      oldWidget.focus?.removeListener(_onFocus);
      widget.focus?.addListener(_onFocus);
    }
    if (oldWidget.thisDeviceOnly != widget.thisDeviceOnly) {
      (oldWidget.thisDeviceOnly ?? _ownFilter)?.removeListener(_onFilter);
      _filter.addListener(_onFilter);
    }
    if (oldWidget.showSystemEvents != widget.showSystemEvents) {
      (oldWidget.showSystemEvents ?? _ownSystem)?.removeListener(_onFilter);
      _system.addListener(_onFilter);
    }
  }

  void _onFilter() => setState(() {});

  @override
  void dispose() {
    widget.log.removeListener(_onEvent);
    widget.focus?.removeListener(_onFocus);
    _filter.removeListener(_onFilter);
    _system.removeListener(_onFilter);
    _ownFilter?.dispose();
    _ownSystem?.dispose();
    _unhighlight?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocus() {
    final id = widget.focus?.value;
    if (id == null) return;
    // An event of another device, opened from elsewhere: show them all.
    if (!_ofDevices.any((e) => e.id == id) &&
        widget.log.events.any((e) => e.id == id)) {
      _filter.value = false;
    }
    // A system event, with them hidden: show them.
    if (!_shown.any((e) => e.id == id) &&
        widget.log.events.any((e) => e.id == id)) {
      _system.value = true;
    }
    _unhighlight?.cancel();
    _unhighlight = Timer(EventTimeline.highlightFor, () {
      if (mounted) setState(() => _highlighted = null);
    });
    setState(() => _highlighted = id);
    _reveal(id);
  }

  /// Scrolls [id]'s card into view. Cards far down the list aren't built,
  /// so it first jumps to where the card should be, guessing from the
  /// average card height, until the card is built.
  void _reveal(String id, [int tries = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final card = _cards[id]?.currentContext;
      if (card != null) {
        Scrollable.ensureVisible(
          card,
          alignment: 0.3,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
        return;
      }
      final events = _shown;
      final index = events.indexWhere((e) => e.id == id);
      if (index < 0 || tries >= 8) return;
      if (!_scroll.hasClients) return _reveal(id, tries + 1);
      final p = _scroll.position;
      final perCard = (p.maxScrollExtent + p.viewportDimension) / events.length;
      _scroll.jumpTo((index * perCard).clamp(0, p.maxScrollExtent));
      _reveal(id, tries + 1);
    });
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
    final events = _shown;
    if (events.isEmpty) {
      return FeedMessage(
        icon: Icons.notifications_none,
        message: widget.log.events.isEmpty
            ? 'No events'
            : _ofDevices.isEmpty
            ? 'No events on this device'
            : 'No grabs yet: system events are hidden',
      );
    }
    return ListView.separated(
      controller: _scroll,
      padding: widget.padding,
      itemCount: events.length,
      separatorBuilder: (context, i) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final event = events[i];
        final card = KeyedSubtree(
          key: _cards.putIfAbsent(event.id, GlobalKey.new),
          child: event.buildCard(context),
        );
        if (event.id != _highlighted) return card;
        return DecoratedBox(
          key: const Key('event-highlight'),
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: card,
        );
      },
    );
  }
}

/// The "Only this device" filter chip, with a check while on, switching
/// [value] (the timeline's filter, [EventTimeline.thisDeviceOnly]).
class ThisDeviceOnly extends StatelessWidget {
  const ThisDeviceOnly({super.key, required this.value});

  final ValueNotifier<bool> value;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: value,
    builder: (context, on, _) => FilterChip(
      key: const Key('this-device-only'),
      selected: on,
      onSelected: (selected) => value.value = selected,
      avatar: on ? null : const Icon(Icons.devices_other, size: 18),
      label: const Text('Only this device'),
    ),
  );
}

/// The "Show system events" filter chip, with a check while on, switching
/// [value] (the timeline's [EventTimeline.showSystemEvents]). On in DEV, off
/// otherwise, at launch.
class ShowSystemEvents extends StatelessWidget {
  const ShowSystemEvents({super.key, required this.value});

  final ValueNotifier<bool> value;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: value,
    builder: (context, on, _) => FilterChip(
      key: const Key('show-system-events'),
      selected: on,
      onSelected: (selected) => value.value = selected,
      avatar: on ? null : const Icon(Icons.settings_suggest, size: 18),
      label: const Text('Show system events'),
    ),
  );
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
