import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'annotations.dart';
import 'camera_feeds.dart';
import 'clips.dart';
import 'event_flags.dart';
import 'identity/device_os.dart';
import 'location/device_location.dart';
import 'recognition/suggestion.dart';

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

  /// Takes the events [ids] out of the log (deleted from storage).
  void remove(Set<String> ids) {
    final before = _events.length;
    _events.removeWhere((e) => ids.contains(e.id));
    if (_events.length != before) notifyListeners();
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
    if (changed) notifyListeners();
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
    this.onlyDevice,
    this.showSystemEvents,
    this.search,
    this.padding = const EdgeInsets.all(12),
  });

  final EventLog log;

  /// Around the cards, inside the scrolling list.
  final EdgeInsets padding;

  /// This device's ID: events without a device ID (not saved yet) are its.
  final String? deviceId;

  /// The one device whose events show, set by tapping an event's device
  /// ([EventDeviceTag]) and cleared with the [DeviceFilterChip] at the top
  /// of the Monitoring tab; null, every device's. Kept by the caller, so it
  /// survives the tab being rebuilt; defaults to an own one, null.
  final ValueNotifier<String?>? onlyDevice;

  /// Whether system events show (the [ShowSystemEvents] toggle): on, every
  /// event, such as "Application started" and sign-ins; off, only grabs
  /// ([isGrab]: clips, by hand, on motion, at start, on a schedule or for
  /// Capture all, and the suggestions about clips). Kept by the caller;
  /// defaults to an own one, on.
  final ValueNotifier<bool>? showSystemEvents;

  /// The [EventSearch] text: only the events it matches ([eventMatches])
  /// show; blank, every one. Kept by the caller; defaults to an own one,
  /// blank.
  final ValueNotifier<String>? search;

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
  static List<AppEvent> matching(List<AppEvent> events, String query) {
    if (query.trim().isEmpty) return events;
    return [
      for (final e in events)
        if (eventMatches(e, query)) e,
    ];
  }

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

  ValueNotifier<String?>? _ownFilter;
  ValueNotifier<String?> get _filter =>
      widget.onlyDevice ?? (_ownFilter ??= ValueNotifier(null));

  ValueNotifier<bool>? _ownSystem;
  ValueNotifier<bool> get _system =>
      widget.showSystemEvents ?? (_ownSystem ??= ValueNotifier(true));

  /// The events of the device shown ([_filter]), or of every device.
  /// Events not saved yet have no device ID; they're this device's.
  List<AppEvent> get _ofDevices => EventTimeline.ofDevices(
    widget.log.events,
    deviceId: widget.deviceId,
    onlyDevice: _filter.value,
  );

  ValueNotifier<String>? _ownSearch;
  ValueNotifier<String> get _search =>
      widget.search ?? (_ownSearch ??= ValueNotifier(''));

  /// [_ofDevices], only the grabs while [_system] is off.
  List<AppEvent> get _ofKinds =>
      EventTimeline.ofKinds(_ofDevices, showSystemEvents: _system.value);

  /// The events shown: [_ofKinds], only those matching [_search].
  List<AppEvent> get _shown => EventTimeline.matching(_ofKinds, _search.value);

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
    _search.addListener(_onFilter);
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
    if (oldWidget.onlyDevice != widget.onlyDevice) {
      (oldWidget.onlyDevice ?? _ownFilter)?.removeListener(_onFilter);
      _filter.addListener(_onFilter);
    }
    if (oldWidget.showSystemEvents != widget.showSystemEvents) {
      (oldWidget.showSystemEvents ?? _ownSystem)?.removeListener(_onFilter);
      _system.addListener(_onFilter);
    }
    if (oldWidget.search != widget.search) {
      (oldWidget.search ?? _ownSearch)?.removeListener(_onFilter);
      _search.addListener(_onFilter);
    }
  }

  void _onFilter() => setState(() {});

  @override
  void dispose() {
    widget.log.removeListener(_onEvent);
    widget.focus?.removeListener(_onFocus);
    _filter.removeListener(_onFilter);
    _system.removeListener(_onFilter);
    _search.removeListener(_onFilter);
    _ownFilter?.dispose();
    _ownSystem?.dispose();
    _ownSearch?.dispose();
    _unhighlight?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onFocus() {
    final id = widget.focus?.value;
    if (id == null) return;
    // An event of another device than the one shown, opened from
    // elsewhere: show every device.
    if (!_ofDevices.any((e) => e.id == id) &&
        widget.log.events.any((e) => e.id == id)) {
      _filter.value = null;
    }
    // A system event, with them hidden: show them.
    if (!_ofKinds.any((e) => e.id == id) &&
        widget.log.events.any((e) => e.id == id)) {
      _system.value = true;
    }
    // An event the search hides: clear it.
    if (!_shown.any((e) => e.id == id) &&
        widget.log.events.any((e) => e.id == id)) {
      _search.value = '';
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
    if (_search.value.trim().isEmpty) return _list(context);
    // Recognition tags clips once they're recorded: match again when a
    // clip's tags or object tags change.
    return ListenableBuilder(
      listenable: Listenable.merge([
        for (final e in _ofKinds)
          if (e is ClipRequested) e.annotations,
      ]),
      builder: (context, _) => _list(context),
    );
  }

  Widget _list(BuildContext context) {
    final events = _shown;
    if (events.isEmpty) {
      return FeedMessage(
        icon: Icons.notifications_none,
        message: widget.log.events.isEmpty
            ? 'No events'
            : _ofDevices.isEmpty
            ? 'No events on ${_filter.value}'
            : _ofKinds.isEmpty
            ? 'No grabs yet: system events are hidden'
            : 'No events match "${_search.value.trim()}"',
      );
    }
    // The cards' tags and subjects filter the search when tapped
    // ([EventSearchScope]).
    return EventSearchScope(
      search: _search,
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
            child: device == null
                ? event.buildCard(context)
                // The device it was taken on, above the card: tapping it
                // shows only that device's events.
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: EventDeviceTag(
                          key: Key('event-device-${event.id}'),
                          device: device,
                          thisDevice: device == widget.deviceId,
                          os: event.os,
                          value: _filter,
                        ),
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

/// Makes the Events search ([EventTimeline.search]) reachable from the
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
/// and for a clip its camera's label, the names tagged on it (not
/// suggestions waiting for an answer) and its object tags (`cat`,
/// `bicycle`…). Add a field here to make it
/// searchable.
Iterable<String> eventSearchFields(AppEvent event) sync* {
  yield event.title;
  if (event.detail case final detail?) yield detail;
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
bool eventMatches(AppEvent event, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return eventSearchFields(event).any((f) => f.toLowerCase().contains(q));
}

/// The events search at the top of the Monitoring tab: a search icon
/// button until tapped, then a text field, focused so the user can type;
/// what's typed goes to [value] (the timeline's [EventTimeline.search]) as
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
/// every event of [profileId] on this device ([EventTimeline.ofProfile]: recorded
/// here, restored, or fetched from the cloud, so it grows as sync brings
/// more), and *matching* those of them left after the search and the
/// filters, with the same steps as the [EventTimeline].
class EventCount extends StatelessWidget {
  const EventCount({
    super.key,
    required this.log,
    required this.profileId,
    required this.deviceId,
    required this.onlyDevice,
    required this.showSystemEvents,
    required this.search,
  });

  final EventLog log;

  /// The signed-in account's profile; null signed out.
  final String? profileId;
  final String? deviceId;
  final ValueListenable<String?> onlyDevice;
  final ValueListenable<bool> showSystemEvents;
  final ValueListenable<String> search;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([log, onlyDevice, showSystemEvents, search]),
    // Recognition tags clips once they're recorded: count again when a
    // clip's tags or object tags change.
    builder: (context, _) => ListenableBuilder(
      listenable: Listenable.merge([
        for (final e in log.events)
          if (e is ClipRequested) e.annotations,
      ]),
      builder: (context, _) {
        final mine = EventTimeline.ofProfile(log.events, profileId);
        final all = mine.length;
        final shown = EventTimeline.matching(
          EventTimeline.ofKinds(
            EventTimeline.ofDevices(
              mine,
              deviceId: deviceId,
              onlyDevice: onlyDevice.value,
            ),
            showSystemEvents: showSystemEvents.value,
          ),
          search.value,
        ).length;
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
    ),
  );
}

/// The device an event was taken on, small and quiet above its card in the
/// timeline: its operating system's icon ([DeviceOs.iconOf]), its ID, this
/// device's in bold, and the operating system's name ([os], left out on
/// events recorded before events had one). Tapping it
/// shows only that device's events ([value], the timeline's
/// [EventTimeline.onlyDevice]); tapped again, every device's.
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
  final ValueNotifier<String?> value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final only = value.value == device;
    final color = only ? scheme.primary : scheme.onSurfaceVariant;
    return Tooltip(
      message: only
          ? 'Show the events of every device'
          : thisDevice
          ? 'Show only this device ($device)'
          : 'Show only $device',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => value.value = only ? null : device,
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
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The device filter at the top of the Monitoring tab, while an event's
/// device ([EventDeviceTag]) shows only its events: a small chip with the
/// device's ID and an x that shows every device again ([value] back to
/// null). Nothing while every device shows.
class DeviceFilterChip extends StatelessWidget {
  const DeviceFilterChip({super.key, required this.value});

  final ValueNotifier<String?> value;

  /// The chip's widest; a long ID is cut short.
  static const double maxWidth = 180;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: value,
    builder: (context, device, _) {
      if (device == null) return const SizedBox.shrink();
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: InputChip(
          key: const Key('device-filter'),
          visualDensity: VisualDensity.compact,
          avatar: const Icon(Icons.devices_other, size: 16),
          label: Text(device, overflow: TextOverflow.ellipsis),
          tooltip: 'Showing only $device',
          onPressed: () => value.value = null,
          deleteButtonTooltipMessage: 'Show every device',
          onDeleted: () => value.value = null,
        ),
      );
    },
  );
}

/// The small "Show system events" toggle at the bottom of the Monitoring
/// tab: an icon, no label (its tooltip names it), highlighted while on,
/// switching [value] (the timeline's [EventTimeline.showSystemEvents]). On
/// in DEV, off otherwise, at launch.
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

String formatEventTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
