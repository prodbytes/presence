import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud/live_sync.dart';
import 'events.dart';
import 'theme.dart';

/// How recently one of the profile's devices showed it's running: [live]
/// (green), [recent] (yellow) or [old] (red, or never).
enum PresenceLevel { live, recent, old }

/// A device's [PresenceLevel], and why, in words ("Live — answered 5 s
/// ago", "Last seen 3 h ago").
class DevicePresence {
  const DevicePresence(this.level, this.reason);

  final PresenceLevel level;
  final String reason;

  /// A device that answered a ping within this is live (green): three
  /// rounds of the 30 s pings the All grid and the devices list send.
  static const Duration liveWithin = Duration(seconds: 90);

  /// A device heard from (an answer, or an event) within this is recently
  /// known (yellow); older, or never, is red.
  static const Duration recentWithin = Duration(hours: 24);

  /// The presence of a device that last answered over live sync at
  /// [answeredAt] ([LiveSync.seenOf]) and whose latest event is from
  /// [lastEvent], at [now]. [liveAvailable]: live sync is on here (without
  /// it nothing answers, so nothing is green, and the reason says so).
  /// [thisDevice]: this one, green while [connected] to live sync.
  factory DevicePresence.of({
    DateTime? answeredAt,
    DateTime? lastEvent,
    required DateTime now,
    required bool liveAvailable,
    bool thisDevice = false,
    bool connected = false,
  }) {
    if (thisDevice) {
      return connected
          ? const DevicePresence(
              PresenceLevel.live,
              'Live — this device, connected to live sync',
            )
          : DevicePresence(
              PresenceLevel.recent,
              liveAvailable
                  ? 'This device — not connected to live sync now'
                  : 'This device — live status unavailable',
            );
    }
    final unavailable = liveAvailable ? '' : ' · live status unavailable';
    if (liveAvailable && answeredAt != null) {
      final age = now.difference(answeredAt);
      if (age < liveWithin) {
        return DevicePresence(
          PresenceLevel.live,
          'Live — answered ${describeSince(age)}',
        );
      }
    }
    final last = switch ((answeredAt, lastEvent)) {
      (final a?, final e?) => a.isAfter(e) ? a : e,
      (final a?, null) => a,
      (null, final e?) => e,
      (null, null) => null,
    };
    if (last == null) {
      return DevicePresence(PresenceLevel.old, 'Never seen$unavailable');
    }
    final age = now.difference(last);
    return DevicePresence(
      age < recentWithin ? PresenceLevel.recent : PresenceLevel.old,
      'Last seen ${describeSince(age)}$unavailable',
    );
  }

  Color get color => switch (level) {
    PresenceLevel.live => Gruvbox.green,
    PresenceLevel.recent => Gruvbox.yellow,
    PresenceLevel.old => Gruvbox.red,
  };
}

/// "5 s ago", "4 min ago", "3 h ago", "2 d ago" ("just now" under a
/// second, or for a time a clock put ahead).
String describeSince(Duration age) {
  if (age.inSeconds < 1) return 'just now';
  if (age.inMinutes < 1) return '${age.inSeconds} s ago';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// The time of each device's latest event in [events] (of [profileId],
/// when set).
Map<String, DateTime> lastEventByDevice(
  Iterable<AppEvent> events, {
  String? profileId,
}) {
  final latest = <String, DateTime>{};
  for (final event in events) {
    final device = event.deviceId;
    if (device == null) continue;
    if (profileId != null && event.profileId != profileId) continue;
    final known = latest[device];
    if (known == null || event.time.isAfter(known)) {
      latest[device] = event.time;
    }
  }
  return latest;
}

/// Whether [live] can tell which devices answer: on (an endpoint, not
/// Never, signed in).
bool liveAvailable(LiveSync? live) =>
    live != null && live.enabled && live.state != LiveSyncState.off;

/// A small dot in [presence]'s color, with its reason as a tooltip and to
/// screen readers.
class PresenceDot extends StatelessWidget {
  const PresenceDot({super.key, required this.presence, this.size = 10});

  final DevicePresence presence;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: presence.reason,
    child: Semantics(
      label: presence.reason,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: presence.color,
          shape: BoxShape.circle,
        ),
      ),
    ),
  );
}

/// Pings the profile's devices ([LiveSync.ping]) when it shows and every
/// [every] while it does, and rebuilds [builder] then (and as answers
/// come), so its presence dots age.
class PresencePinger extends StatefulWidget {
  const PresencePinger({
    super.key,
    required this.live,
    required this.builder,
    this.every = const Duration(seconds: 30),
  });

  final LiveSync? live;
  final WidgetBuilder builder;
  final Duration every;

  @override
  State<PresencePinger> createState() => _PresencePingerState();
}

class _PresencePingerState extends State<PresencePinger> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.live?.ping().ignore();
    _timer = Timer.periodic(widget.every, (_) {
      widget.live?.ping().ignore();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    if (live == null) return widget.builder(context);
    return ListenableBuilder(
      listenable: live,
      builder: (c, _) => widget.builder(c),
    );
  }
}
