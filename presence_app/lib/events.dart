import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'annotations.dart';
import 'camera_feeds.dart';
import 'clips.dart';
import 'copies_badge.dart';
import 'event_filters.dart';
import 'event_flags.dart';
import 'identity/device_os.dart';
import 'location/device_location.dart';
import 'recognition/suggestion.dart';
import 'time_format.dart';

export 'event_filters.dart' show EventFilters, EventView;
export 'time_format.dart' show formatEventTime;

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
    this.profileId,
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
    String? profileId,
  }) : this(
         icon: Icons.power_settings_new,
         title: 'Application started',
         type: appStartedType,
         time: time,
         id: id,
         deviceId: deviceId,
         userId: userId,
         profileId: profileId,
       );

  /// The Clip button was pressed with the Camera tab's All grid showing:
  /// every device of the profile takes a clip. It reaches the other devices
  /// through cloud sync, and each answers with a clip of its own
  /// (`CameraRig.answerCaptureAll`).
  AppEvent.captureAll({
    DateTime? time,
    String? id,
    String? deviceId,
    String? userId,
    String? profileId,
  }) : this(
         icon: Icons.grid_view,
         title: 'Capture all',
         detail: 'Every device takes a clip',
         type: captureAllType,
         time: time,
         id: id,
         deviceId: deviceId,
         userId: userId,
         profileId: profileId,
       );

  static const String genericType = 'generic';
  static const String appStartedType = 'app_started';
  static const String captureAllType = 'capture_all';

  /// The [userId] of events recorded while nobody was signed in. The next
  /// user to sign in on the device takes them over, with their profile
  /// (`Persistence.claimForProfile`).
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

  /// Who was signed in when the event was recorded: their Google ID, or
  /// [anonymousUserId]. Set when it's saved, and changed once, from
  /// anonymous, when a user signs in on the device.
  String? userId;

  /// The profile the event belongs to (`automatic_paranoid_axolotl`): the
  /// signed-in account's when it was saved. Null while nobody is signed in
  /// (or before the auth API answers a sign-in): then the next sign-in on
  /// the device gives it its profile (`Persistence.claimForProfile`). Only
  /// events with a profile sync.
  String? profileId;

  /// Where the device was when the event was published: its own position,
  /// or the one set on the Device screen's map. Null while it's unknown.
  DeviceLocation? location;

  /// The operating system of the device that recorded the event
  /// (`DeviceOs.current`, such as `Android` or `Web (Chrome, macOS)`). Set
  /// when it's saved; null on events saved before events had one.
  String? os;

  /// When the event was deleted, with every other event of its device
  /// (`Persistence.deleteDevice`): a soft delete. The record stays, with
  /// this time, in storage and in the cloud, so the deletion syncs to the
  /// profile's other devices; deleted events are kept out of the
  /// [EventLog], so nothing shows them. Null: not deleted.
  DateTime? deletedAt;

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
    'profileId': profileId,
    'location': location?.toJson(),
    if (os != null) 'os': os,
    if (deletedAt case final at?) deletedAtField: at.millisecondsSinceEpoch,
  };

  /// The record field of [deletedAt], in ms since the epoch.
  static const String deletedAtField = 'deletedAt';

  /// Whether a stored event is deleted ([deletedAt]): kept, but shown
  /// nowhere.
  static bool isDeletedRecord(Map<String, Object?> record) =>
      record[deletedAtField] is int;

  /// When a stored event was deleted; null if it isn't.
  static DateTime? deletedAtOf(Map<String, Object?> record) =>
      switch (record[deletedAtField]) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        _ => null,
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
      captureAllType => AppEvent.captureAll(
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
    return event
      ?..location = DeviceLocation.fromJson(record['location'])
      ..profileId = profileOf(record)
      ..os = osOf(record)
      ..deletedAt = deletedAtOf(record);
  }

  /// The operating system a stored event was recorded on; null if it
  /// doesn't say.
  static String? osOf(Map<String, Object?> record) {
    final os = record['os'];
    return os is String && os.isNotEmpty ? os : null;
  }

  /// Who was signed in when a stored event was recorded. Events saved
  /// before events had owners count as anonymous.
  static String ownerOf(Map<String, Object?> record) =>
      record['userId'] as String? ?? anonymousUserId;

  /// The profile a stored event belongs to; null if none yet.
  static String? profileOf(Map<String, Object?> record) {
    final id = record['profileId'];
    return id is String && id.isNotEmpty ? id : null;
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

  /// What about this event wants attention (see [EventFlag]), worked out
  /// from its data; none for most events.
  List<EventFlag> get flags => const [];

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
///
/// Notifies when events are added, removed or replaced; [annotations]
/// notifies, separately, when a clip's tags or object tags change.
class EventLog extends ChangeNotifier {
  EventLog(Stream<AppEvent> events) {
    _subscription = events.listen(_add);
  }

  late final StreamSubscription<AppEvent> _subscription;
  final List<AppEvent> _events = [];

  /// The events, newest first: a snapshot that doesn't change with the
  /// log (callers may go through it across awaits), made once per change
  /// and shared until the next.
  List<AppEvent> get events => _snapshot ??= List.unmodifiable(_events);
  List<AppEvent>? _snapshot;

  /// Goes up by one with every change to [events].
  int get version => _version;
  int _version = 0;

  /// [profileId]'s events ([EventTimeline.ofProfile]), kept until the log
  /// changes.
  List<AppEvent> eventsOf(String? profileId) {
    if (_ofProfile case (final v, final p, final list)
        when v == _version && p == profileId) {
      return list;
    }
    final list = List<AppEvent>.unmodifiable(
      EventTimeline.ofProfile(events, profileId),
    );
    _ofProfile = (_version, profileId, list);
    return list;
  }

  (int, String?, List<AppEvent>)? _ofProfile;

  /// Notifies when any clip's tags or object tags change (recognition, a
  /// tag added or removed), so what depends on them (the search, the
  /// subjects) is worked out again; [annotationsVersion] goes up first.
  Listenable get annotations => _annotations;
  final _annotations = _Signal();

  /// Goes up by one with every change to a clip's tags or object tags.
  int get annotationsVersion => _annotationsVersion;
  int _annotationsVersion = 0;

  /// The clips' annotations listened to for [annotations].
  var _watched = Set<ClipAnnotations>.identity();

  void _onAnnotations() {
    _annotationsVersion++;
    _annotations.fire();
  }

  /// Listens to the annotations of the clips now in the log, and no others.
  void _watch() {
    final now = Set<ClipAnnotations>.identity()
      ..addAll(_events.whereType<ClipRequested>().map((e) => e.annotations));
    for (final gone in _watched.difference(now)) {
      gone.removeListener(_onAnnotations);
    }
    for (final added in now.difference(_watched)) {
      added.addListener(_onAnnotations);
    }
    _watched = now;
  }

  void _changed() {
    _version++;
    _snapshot = null;
    _watch();
    notifyListeners();
  }

  void _add(AppEvent event) {
    _events.insert(0, event);
    _changed();
  }

  /// Takes the events [ids] out of the log (deleted from storage).
  void remove(Set<String> ids) {
    final before = _events.length;
    _events.removeWhere((e) => ids.contains(e.id));
    if (_events.length != before) _changed();
  }

  /// Puts [events] in place of the ones in the log with their IDs (shown
  /// again, such as an event whose clip has arrived from the cloud). Events
  /// not in the log are left out.
  void replace(Iterable<AppEvent> events) {
    final byId = {for (final e in events) e.id: e};
    var changed = false;
    for (var i = 0; i < _events.length; i++) {
      final replacement = byId[_events[i].id];
      if (replacement != null && !identical(replacement, _events[i])) {
        _events[i] = replacement;
        changed = true;
      }
    }
    if (changed) _changed();
  }

  /// Adds events restored from storage, keeping the timeline newest first.
  /// Events already in the log (published since launch) are kept. Notifies
  /// only when something was added: a sync with only changes to known
  /// events (their tags, which [annotations] reports) leaves the log as
  /// it is.
  void addHistory(Iterable<AppEvent> history) {
    final known = {for (final e in _events) e.id};
    final added = [
      for (final e in history)
        if (known.add(e.id)) e,
    ];
    if (added.isEmpty) return;
    _events
      ..addAll(added)
      ..sort((a, b) => b.time.compareTo(a.time));
    _changed();
  }

  @override
  void dispose() {
    _subscription.cancel();
    for (final a in _watched) {
      a.removeListener(_onAnnotations);
    }
    _watched.clear();
    _annotations.dispose();
    super.dispose();
  }
}

/// A [ChangeNotifier] that notifies when [fire]d.
class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// Scrollable timeline of events, newest at the top.
class EventTimeline extends StatefulWidget {
  const EventTimeline({
    super.key,
    required this.log,
    this.filters,
    this.deviceId,
    this.profileId,
    this.padding = const EdgeInsets.all(12),
  });

  final EventLog log;

  /// Around the cards, inside the scrolling list.
  final EdgeInsets padding;

  /// This device's ID: events without a device ID (not saved yet) are its.
  final String? deviceId;

  /// The signed-in account's profile (null signed out): only its events
  /// show ([ofProfile]), as the [EventCount] counts them.
  final String? profileId;

  /// What shows ([EventFilters]: the device picked, system events, the
  /// search) and the event to open ([EventFilters.focus]). Kept by the
  /// caller, so they survive the tab being rebuilt; defaults to an own
  /// one, showing every event.
  final EventFilters? filters;

  /// Whether [event] is a grab, shown even with system events hidden: a
  /// clip (Capture all's too) or a suggestion about a clip ("Is this
  /// Rex?"), which waits for an answer. A Capture all request has no
  /// video of its own: it's a system event.
  static bool isGrab(AppEvent event) =>
      event is ClipRequested || event is SubjectSuggestion;

  /// [events] of [profileId], the signed-in account's profile (null
  /// signed out): its own, and those without a profile (recorded signed
  /// out, or not saved yet), which the next sign-in gives its profile
  /// (`Persistence.claimForProfile`).
  static List<AppEvent> ofProfile(List<AppEvent> events, String? profileId) => [
    for (final e in events)
      if (e.profileId == null || e.profileId == profileId) e,
  ];

  /// The device [event] was taken on: its device ID, or, not saved yet
  /// (no device ID), this device's ([deviceId]).
  static String? deviceOf(AppEvent event, String? deviceId) =>
      event.deviceId ?? deviceId;

  /// [events] of [onlyDevice] ([deviceOf]); null, every device's.
  static List<AppEvent> ofDevices(
    List<AppEvent> events, {
    required String? deviceId,
    required String? onlyDevice,
  }) {
    if (onlyDevice == null) return events;
    return [
      for (final e in events)
        if (deviceOf(e, deviceId) == onlyDevice) e,
    ];
  }

  /// [events], only the grabs ([isGrab]) unless [showSystemEvents].
  static List<AppEvent> ofKinds(
    List<AppEvent> events, {
    required bool showSystemEvents,
  }) => showSystemEvents ? events : events.where(isGrab).toList();

  /// [events], only those matching [query] ([eventMatches]); blank, all.
  /// Events without a device ID (not saved yet) are [deviceId]'s.
  static List<AppEvent> matching(
    List<AppEvent> events,
    String query, {
    String? deviceId,
  }) {
    if (query.trim().isEmpty) return events;
    return [
      for (final e in events)
        if (eventMatches(e, query, deviceId: deviceId)) e,
    ];
  }

  /// How long an event opened through [EventFilters.focus] stays outlined.
  static const Duration highlightFor = Duration(seconds: 4);

  /// A new event at the top scrolls the list back up to it only when the
  /// list is scrolled less than this far down: further down, the user is
  /// reading older events and stays where they are.
  static const double followNewWithin = 200;

  @override
  State<EventTimeline> createState() => _EventTimelineState();
}

class _EventTimelineState extends State<EventTimeline> {
  final _scroll = ScrollController();

  EventFilters? _ownFilters;
  EventFilters get _filters =>
      widget.filters ?? (_ownFilters ??= EventFilters());

  /// The events at each filter step ([EventFilters.viewOf]).
  EventView get _view => _filters.viewOf(
    widget.log,
    deviceId: widget.deviceId,
    profileId: widget.profileId,
  );

  /// Each shown card's key, to find it once it's built.
  final _cards = <String, GlobalKey>{};

  /// The newest event shown, to tell a new event from other changes.
  String? _newest;

  /// The outlined event, while [EventTimeline.highlightFor] lasts.
  String? _highlighted;
  Timer? _unhighlight;

  @override
  void initState() {
    super.initState();
    _listen(widget.log, _filters);
    _newest = _view.shown.firstOrNull?.id;
    // The tab may be built only once the event was asked for.
    _onFocusRequest();
  }

  void _listen(EventLog log, EventFilters filters) {
    log.addListener(_onEvent);
    log.annotations.addListener(_onAnnotations);
    filters.addListener(_onFilter);
    filters.focusRequests.addListener(_onFocusRequest);
  }

  void _unlisten(EventLog log, EventFilters filters) {
    log.removeListener(_onEvent);
    log.annotations.removeListener(_onAnnotations);
    filters.removeListener(_onFilter);
    filters.focusRequests.removeListener(_onFocusRequest);
  }

  @override
  void didUpdateWidget(EventTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldFilters = oldWidget.filters ?? _ownFilters!;
    if (oldWidget.log != widget.log || oldFilters != _filters) {
      _unlisten(oldWidget.log, oldFilters);
      _listen(widget.log, _filters);
      _newest = _view.shown.firstOrNull?.id;
    }
  }

  @override
  void dispose() {
    _unlisten(widget.log, _filters);
    _ownFilters?.dispose();
    _unhighlight?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onFilter() {
    _newest = _view.shown.firstOrNull?.id;
    setState(() {});
  }

  /// A clip's tags changed: the search matches again ([EventLog.annotations]).
  /// The cards follow their own tags; without a search, nothing else does.
  void _onAnnotations() {
    if (_filters.search.value.trim().isNotEmpty) setState(() {});
  }

  /// Handles an event asked for with [EventFilters.focus], once. Asked for
  /// while the tree builds (this timeline just built, in [initState]), only
  /// after the frame: it may change the filters, which other widgets show,
  /// and those mustn't change during a build.
  void _onFocusRequest() {
    void handle() {
      if (!mounted) return;
      if (_filters.takeFocus() case final id?) _focus(id);
    }

    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      handle();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => handle());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  /// Shows [id]: clears whichever filter hides it, scrolls to it and
  /// outlines it for [EventTimeline.highlightFor].
  void _focus(String id) {
    bool hasIt(List<AppEvent> events) => events.any((e) => e.id == id);
    // Only the profile's events can show.
    if (hasIt(_view.mine)) {
      // An event of another device than the one searched for, opened
      // from elsewhere: show every device.
      if (!hasIt(_view.ofDevices)) _filters.search.value = '';
      // A system event, with them hidden: show them.
      if (!hasIt(_view.ofKinds)) _filters.showSystemEvents.value = true;
      // An event the search hides: clear it.
      if (!hasIt(_view.shown)) _filters.search.value = '';
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
      final events = _view.shown;
      final index = events.indexWhere((e) => e.id == id);
      if (index < 0 || tries >= 8) return;
      if (!_scroll.hasClients) return _reveal(id, tries + 1);
      final p = _scroll.position;
      final perCard = (p.maxScrollExtent + p.viewportDimension) / events.length;
      _scroll.jumpTo((index * perCard).clamp(0, p.maxScrollExtent));
      _reveal(id, tries + 1);
    });
  }

  /// The log changed. Only a new event at the top brings the list back up
  /// to it, and only when it's near the top already: a sync that only
  /// changed or added older events leaves it where the user scrolled.
  void _onEvent() {
    final newest = _view.shown.firstOrNull?.id;
    final arrived = newest != null && newest != _newest;
    _newest = newest;
    setState(() {});
    if (!arrived) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_scroll.offset > EventTimeline.followNewWithin) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    final events = view.shown;
    // Keys only for the cards that can show.
    final shownIds = {for (final e in events) e.id};
    _cards.removeWhere((id, _) => !shownIds.contains(id));
    if (events.isEmpty) {
      return FeedMessage(
        icon: Icons.notifications_none,
        message: view.mine.isEmpty
            ? 'No events'
            : view.ofKinds.isEmpty
            ? 'No grabs yet: system events are hidden'
            : 'No events match "${_filters.search.value.trim()}"',
      );
    }
    // The cards' tags and subjects filter the search when tapped
    // ([EventSearchScope]).
    return EventSearchScope(
      search: _filters.search,
      child: ListView.separated(
        controller: _scroll,
        padding: widget.padding,
        itemCount: events.length,
        separatorBuilder: (context, i) => const SizedBox(height: 4),
        itemBuilder: (context, i) {
          final event = events[i];
          final device = EventTimeline.deviceOf(event, widget.deviceId);
          final card = KeyedSubtree(
            key: _cards.putIfAbsent(event.id, GlobalKey.new),
            // Above the card, the device it was taken on (tapping it
            // searches for it: only that device's events show) and how
            // many copies of it there are.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    if (device != null)
                      Flexible(
                        child: EventDeviceTag(
                          key: Key('event-device-${event.id}'),
                          device: device,
                          thisDevice: device == widget.deviceId,
                          os: event.os,
                          value: _filters.search,
                        ),
                      ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: EventCopiesBadge(
                        key: Key('event-copies-${event.id}'),
                        event: event,
                      ),
                    ),
                  ],
                ),
                event.buildCard(context),
              ],
            ),
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
      ),
    );
  }
}

/// Makes the Events search ([EventFilters.search]) reachable from the
/// cards in the timeline, and from the clip player opened from one, so a
/// tapped tag or subject filters the events by it ([toggle]) and shows
/// highlighted while it's the search ([isActive]). Cards shown outside a
/// timeline have none; their labels keep their other actions.
class EventSearchScope extends InheritedNotifier<ValueNotifier<String>> {
  const EventSearchScope({
    super.key,
    required ValueNotifier<String> search,
    required super.child,
  }) : super(notifier: search);

  /// The search, rebuilding [context] when it changes; null outside a
  /// timeline.
  static ValueNotifier<String>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EventSearchScope>()?.notifier;

  /// The search, without rebuilding [context] when it changes (for event
  /// handlers); null outside a timeline.
  static ValueNotifier<String>? peek(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EventSearchScope>()?.notifier;

  /// Whether the search [query] is [label]: the tag or subject filtered by,
  /// ignoring case and the spaces around them.
  static bool isActive(String query, String label) {
    final q = query.trim().toLowerCase();
    return q.isNotEmpty && q == label.trim().toLowerCase();
  }

  /// A tapped tag or subject: searches for [label], or, already the search,
  /// clears it.
  static void toggle(ValueNotifier<String> search, String label) =>
      search.value = isActive(search.value, label) ? '' : label.trim();
}

/// The texts the Events search looks in for [event]: its title and detail,
/// the device it was taken on ([EventTimeline.deviceOf]: without a device
/// ID, [deviceId], this device's), and for a clip its camera's label, the
/// names tagged on it (not suggestions waiting for an answer) and its
/// object tags (`cat`, `bicycle`…). Add a field here to make it
/// searchable.
Iterable<String> eventSearchFields(AppEvent event, {String? deviceId}) sync* {
  yield event.title;
  if (event.detail case final detail?) yield detail;
  if (EventTimeline.deviceOf(event, deviceId) case final device?) {
    yield device;
  }
  final clip = switch (event) {
    ClipRequested() => event,
    SubjectSuggestion(:final clip) => clip,
    _ => null,
  };
  if (clip != null) {
    yield clip.clip.cameraLabel;
    // A suggestion's own name is in its title; its clip's tags aren't it.
    if (event is ClipRequested) {
      for (final tag in clip.annotations.tags) {
        yield tag.name;
      }
      for (final object in clip.annotations.objects ?? const <ObjectTag>[]) {
        yield object.label;
      }
    }
  }
  // "unidentified" finds the events with someone to name.
  for (final flag in event.flags) {
    yield flag.name;
  }
}

/// Whether [event] matches the Events search [query]: one of its
/// [eventSearchFields] contains it, ignoring case and the spaces around
/// it. A blank query matches every event.
bool eventMatches(AppEvent event, String query, {String? deviceId}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return eventSearchFields(
    event,
    deviceId: deviceId,
  ).any((f) => f.toLowerCase().contains(q));
}

/// The events search at the top of the Monitoring tab: a search icon
/// button until tapped, then a text field, focused so the user can type;
/// what's typed goes to [value] (the timeline's [EventFilters.search]) as
/// it's typed. It folds back into the icon when it loses focus empty, or
/// with its x, which clears it first; while it has text it stays open.
class EventSearch extends StatefulWidget {
  const EventSearch({super.key, required this.value});

  final ValueNotifier<String> value;

  /// The open field's widest; it gives up room on a narrow phone.
  static const double maxWidth = 280;

  @override
  State<EventSearch> createState() => _EventSearchState();
}

class _EventSearchState extends State<EventSearch> {
  late final _controller = TextEditingController(text: widget.value.value);
  final _focus = FocusNode(debugLabel: 'event-search');

  /// Whether the field shows: open with a search kept from before.
  late bool _open = widget.value.value.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.value.addListener(_onValue);
    _focus.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(EventSearch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      oldWidget.value.removeListener(_onValue);
      widget.value.addListener(_onValue);
      _onValue();
    }
  }

  @override
  void dispose() {
    widget.value.removeListener(_onValue);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Follows [EventSearch.value] when it's changed elsewhere (cleared when
  /// an event it hides is opened).
  void _onValue() {
    final text = widget.value.value;
    if (_controller.text != text) _controller.text = text;
    if (text.isNotEmpty && !_open) setState(() => _open = true);
    if (text.isEmpty && _open && !_focus.hasFocus) {
      setState(() => _open = false);
    }
  }

  /// Folds back once it's left empty.
  void _onFocus() {
    if (!_focus.hasFocus && _controller.text.isEmpty && _open) {
      setState(() => _open = false);
    }
  }

  void _close() {
    _controller.clear();
    widget.value.value = '';
    _focus.unfocus();
    setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return IconButton(
        key: const Key('event-search-open'),
        tooltip: 'Search events',
        icon: const Icon(Icons.search),
        onPressed: () {
          setState(() => _open = true);
          // Focused once it's built, so the keyboard comes up.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _focus.requestFocus();
          });
        },
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: EventSearch.maxWidth),
      child: TextField(
        key: const Key('event-search'),
        controller: _controller,
        focusNode: _focus,
        onChanged: (text) => widget.value.value = text,
        onSubmitted: (text) {
          if (text.isEmpty) _close();
        },
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search events',
          prefixIcon: const Icon(Icons.search, size: 20),
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            key: const Key('event-search-clear'),
            tooltip: 'Clear search',
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: _close,
          ),
        ),
      ),
    );
  }
}

/// The event counts beside the [EventSearch], as "3 / 12": *all* is
/// every event of [profileId] on this device ([EventTimeline.ofProfile]:
/// recorded here, restored, or fetched from the cloud, so it grows as sync
/// brings more), and *matching* those of them left after the search and
/// the filters: what the [EventTimeline] shows, from the same
/// [EventFilters.viewOf].
class EventCount extends StatelessWidget {
  const EventCount({
    super.key,
    required this.log,
    required this.filters,
    required this.profileId,
    required this.deviceId,
  });

  final EventLog log;
  final EventFilters filters;

  /// The signed-in account's profile; null signed out.
  final String? profileId;
  final String? deviceId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Recognition tags clips once they're recorded: count again when a
    // clip's tags or object tags change.
    listenable: Listenable.merge([log, filters, log.annotations]),
    builder: (context, _) {
      final view = filters.viewOf(
        log,
        deviceId: deviceId,
        profileId: profileId,
      );
      final all = view.mine.length;
      final shown = view.shown.length;
      final theme = Theme.of(context);
      return Tooltip(
        message: '$shown of $all events shown',
        child: Text(
          '$shown / $all',
          key: const Key('event-count'),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      );
    },
  );
}

/// The device an event was taken on, small and quiet above its card in the
/// timeline: its operating system's icon ([DeviceOs.iconOf]), its ID, this
/// device's in bold, and the operating system's name ([os], left out on
/// events recorded before events had one). Tapping it searches for the
/// device ([value], the timeline's [EventFilters.search]): only its events
/// show ([EventFilters.showDevice]); tapped again, the search clears and
/// every device's show.
class EventDeviceTag extends StatelessWidget {
  const EventDeviceTag({
    super.key,
    required this.device,
    required this.thisDevice,
    required this.value,
    this.os,
  });

  final String device;

  /// The operating system the event was recorded on, if it says.
  final String? os;

  /// Whether [device] is this device.
  final bool thisDevice;

  /// The events search ([EventFilters.search]).
  final ValueNotifier<String> value;

  /// The tooltip of a device name that shows its events (here, and
  /// `ShowDeviceEvents` elsewhere).
  static const String showTooltip = "Show this device's events";

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final only = EventSearchScope.isActive(value.value, device);
    final color = only ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: only ? "Show every device's events" : showTooltip,
      child: Semantics(
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => EventSearchScope.toggle(value, device),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(DeviceOs.iconOf(os), size: 14, color: color),
                  const SizedBox(width: 4),
                  Flexible(
                    flex: 3,
                    child: Text(
                      device,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: thisDevice || only ? FontWeight.bold : null,
                      ),
                    ),
                  ),
                  if (os case final os?)
                    Flexible(
                      flex: 2,
                      child: Text(
                        ' · $os',
                        key: const Key('event-device-os'),
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: color,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small "Show system events" toggle in the Monitoring tab's top row,
/// after the count: an icon, no label (its tooltip names it), highlighted
/// while on, switching [value] ([EventFilters.showSystemEvents]). On in
/// DEV, off otherwise, at launch.
class ShowSystemEvents extends StatelessWidget {
  const ShowSystemEvents({super.key, required this.value});

  final ValueNotifier<bool> value;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: value,
    builder: (context, on, _) {
      final scheme = Theme.of(context).colorScheme;
      return IconButton(
        key: const Key('show-system-events'),
        isSelected: on,
        tooltip: on ? 'Hide system events' : 'Show system events',
        visualDensity: VisualDensity.compact,
        iconSize: 18,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
        selectedIcon: Icon(Icons.settings_suggest, color: scheme.primary),
        icon: const Icon(Icons.settings_suggest_outlined),
        onPressed: () => value.value = !on,
      );
    },
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
