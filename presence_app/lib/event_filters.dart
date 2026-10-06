import 'package:flutter/foundation.dart';

import 'events.dart';

/// What the Monitoring tab shows of the [EventLog], in one place: the one
/// device picked ([onlyDevice]), the "Show system events" toggle
/// ([showSystemEvents]) and the search ([search]), plus the event asked to
/// be opened ([focus]). Kept by the home screen so the choices survive the
/// tab being rebuilt; the timeline, the count and the subjects map all read
/// the same [viewOf], so they always agree.
///
/// Notifies when [onlyDevice], [showSystemEvents] or [search] change;
/// [focusRequests] notifies, separately, when an event is asked for.
class EventFilters extends ChangeNotifier {
  EventFilters({
    String? onlyDevice,
    bool showSystemEvents = true,
    String search = '',
  }) : onlyDevice = ValueNotifier(onlyDevice),
       showSystemEvents = ValueNotifier(showSystemEvents),
       search = ValueNotifier(search) {
    for (final part in _parts) {
      part.addListener(notifyListeners);
    }
  }

  /// The one device whose events show, set by tapping an event's device
  /// ([EventDeviceTag]) and cleared with the [DeviceFilterChip]; null,
  /// every device's.
  final ValueNotifier<String?> onlyDevice;

  /// Whether system events show ([ShowSystemEvents]): on, every event; off,
  /// only grabs ([EventTimeline.isGrab]).
  final ValueNotifier<bool> showSystemEvents;

  /// The [EventSearch] text: only the events it matches ([eventMatches])
  /// show; blank, every one.
  final ValueNotifier<String> search;

  List<ValueNotifier<Object?>> get _parts => [
    onlyDevice,
    showSystemEvents,
    search,
  ];

  // Focus: a one-shot request. Each [focus] call is a new request, handled
  // once ([takeFocus]), so a timeline built again later (the tab shown
  // again) doesn't open it again.
  final _focusRequests = _Signal();
  String? _focusId;
  int _focusAsked = 0;
  int _focusTaken = 0;

  /// Notifies when [focus] asks for an event.
  Listenable get focusRequests => _focusRequests;

  /// Asks the timeline to scroll to [eventId] and outline it (an event
  /// opened from elsewhere, such as a subject's map). Asking again, even
  /// for the same event, scrolls to it again.
  void focus(String eventId) {
    _focusId = eventId;
    _focusAsked++;
    _focusRequests.fire();
  }

  /// The event asked for with [focus] and not handled yet, marking it
  /// handled; null if there's none.
  String? takeFocus() {
    if (_focusTaken == _focusAsked) return null;
    _focusTaken = _focusAsked;
    return _focusId;
  }

  // Memoized steps of [viewOf], each kept until what it's worked out from
  // changes, so the timeline, the count and the map share one pass.
  (Object, String?, String?)? _devicesKey;
  List<AppEvent> _ofDevices = const [];
  (Object, bool)? _kindsKey;
  List<AppEvent> _ofKinds = const [];
  (Object, String, int)? _shownKey;
  List<AppEvent> _shown = const [];

  /// The events of [log] these filters show, step by step (each step's
  /// list is kept and reused until its inputs change):
  ///
  /// - [EventView.mine]: [profileId]'s events ([EventLog.eventsOf]);
  /// - [EventView.ofDevices]: of them, [onlyDevice]'s, events without a
  ///   device ID being [deviceId]'s;
  /// - [EventView.ofKinds]: of them, only grabs unless [showSystemEvents];
  /// - [EventView.shown]: of them, those matching [search], matched again
  ///   when a clip's tags change ([EventLog.annotationsVersion]).
  EventView viewOf(EventLog log, {String? deviceId, String? profileId}) {
    final mine = log.eventsOf(profileId);
    final devicesKey = (mine, deviceId, onlyDevice.value);
    if (!_sameKey(devicesKey, _devicesKey)) {
      _devicesKey = devicesKey;
      _ofDevices = EventTimeline.ofDevices(
        mine,
        deviceId: deviceId,
        onlyDevice: onlyDevice.value,
      );
    }
    final kindsKey = (_ofDevices, showSystemEvents.value);
    if (!_sameKey(kindsKey, _kindsKey)) {
      _kindsKey = kindsKey;
      _ofKinds = EventTimeline.ofKinds(
        _ofDevices,
        showSystemEvents: showSystemEvents.value,
      );
    }
    final query = search.value;
    // Tags matter only while searching.
    final tags = query.trim().isEmpty ? -1 : log.annotationsVersion;
    final shownKey = (_ofKinds, query, tags);
    if (!_sameKey(shownKey, _shownKey)) {
      _shownKey = shownKey;
      _shown = EventTimeline.matching(_ofKinds, query);
    }
    return EventView(
      all: log.events,
      mine: mine,
      ofDevices: _ofDevices,
      ofKinds: _ofKinds,
      shown: _shown,
    );
  }

  /// Keys are records whose first field is a list, compared by identity
  /// (the lists are kept, never changed); the rest by value.
  static bool _sameKey(Record a, Record? b) => switch ((a, b)) {
    ((final List x, final y, final z), (final List u, final v, final w)) =>
      identical(x, u) && y == v && z == w,
    ((final List x, final y), (final List u, final v)) =>
      identical(x, u) && y == v,
    _ => false,
  };

  @override
  void dispose() {
    for (final part in _parts) {
      part
        ..removeListener(notifyListeners)
        ..dispose();
    }
    _focusRequests.dispose();
    super.dispose();
  }
}

/// The events of an [EventLog] at each step of [EventFilters.viewOf].
@immutable
class EventView {
  const EventView({
    required this.all,
    required this.mine,
    required this.ofDevices,
    required this.ofKinds,
    required this.shown,
  });

  /// Every event in the log.
  final List<AppEvent> all;

  /// The signed-in profile's events ([EventTimeline.ofProfile]).
  final List<AppEvent> mine;

  /// [mine], of the device picked, or of every device.
  final List<AppEvent> ofDevices;

  /// [ofDevices], only the grabs while system events are hidden.
  final List<AppEvent> ofKinds;

  /// [ofKinds], only those matching the search: what the timeline shows.
  final List<AppEvent> shown;
}

/// A [ChangeNotifier] that notifies when [fire]d.
class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}
