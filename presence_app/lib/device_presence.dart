import 'dart:async';

import 'package:flutter/material.dart';

import 'cloud/live_sync.dart';
import 'config.dart';
import 'events.dart';
import 'l10n/l10n.dart';
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

  /// The sync timeout: how long between hearing from a device, as often
  /// as devices sync ([LiveSync.presenceTimeout]); by default a member's
  /// live sync schedule, every minute ([LiveConfig.defaultEvery]).
  static const Duration timeout = LiveConfig.defaultEvery;

  /// Heard from (an answer over live sync, or an event) within this many
  /// [timeout]s: recently active, green.
  static const int liveTimeouts = 5;

  /// Within this many [timeout]s: yellow; longer, or never, red.
  static const int recentTimeouts = 10;

  /// The presence of a device that last answered over live sync at
  /// [answeredAt] ([LiveSync.seenOf]) and whose latest event is from
  /// [lastEvent], at [now]: green when the newer of the two is within
  /// [liveTimeouts] × [timeout], yellow within [recentTimeouts] ×, red
  /// past that or never. [liveAvailable]: live sync is on here (without
  /// it nothing answers, and the reason says so). [thisDevice]: this one,
  /// green while [connected] to live sync (for a free device: its last
  /// heartbeat recent, [LiveSync.showsLive]). The reason is worded in
  /// [l], English by default.
  factory DevicePresence.of({
    AppLocalizations? l,
    DateTime? answeredAt,
    DateTime? lastEvent,
    required DateTime now,
    required bool liveAvailable,
    bool thisDevice = false,
    bool connected = false,
    Duration timeout = DevicePresence.timeout,
  }) {
    final t = l ?? lookupAppLocalizations(const Locale('en'));
    if (thisDevice) {
      return connected
          ? DevicePresence(PresenceLevel.live, t.connectivityPresenceThisLive)
          : DevicePresence(
              PresenceLevel.recent,
              liveAvailable
                  ? t.connectivityPresenceThisNotConnected
                  : t.connectivityPresenceThisUnavailable,
            );
    }
    final unavailable = liveAvailable ? '' : t.connectivityPresenceUnavailable;
    final answered = liveAvailable ? answeredAt : null;
    final last = switch ((answered, lastEvent)) {
      (final a?, final e?) => a.isAfter(e) ? a : e,
      (final a?, null) => a,
      (null, final e?) => e,
      (null, null) => null,
    };
    if (last == null) {
      return DevicePresence(
        PresenceLevel.old,
        t.connectivityPresenceNever(unavailable),
      );
    }
    final age = now.difference(last);
    final level = age < timeout * liveTimeouts
        ? PresenceLevel.live
        : age < timeout * recentTimeouts
        ? PresenceLevel.recent
        : PresenceLevel.old;
    return DevicePresence(
      level,
      level == PresenceLevel.live && last == answered
          ? t.connectivityPresenceAnswered(describeSince(age, t))
          : t.connectivityPresenceLastSeen(describeSince(age, t), unavailable),
    );
  }

  Color get color => switch (level) {
    PresenceLevel.live => Gruvbox.green,
    PresenceLevel.recent => Gruvbox.yellow,
    PresenceLevel.old => Gruvbox.red,
  };
}

/// "5 s ago", "4 min ago", "3 h ago", "2 d ago" ("just now" under a
/// second, or for a time a clock put ahead); in [l], English by default.
String describeSince(Duration age, [AppLocalizations? l]) {
  l ??= lookupAppLocalizations(const Locale('en'));
  if (age.inSeconds < 1) return l.cameraAgeJustNow;
  if (age.inMinutes < 1) return l.cameraAgeSeconds(age.inSeconds);
  if (age.inHours < 1) return l.cameraAgeMinutes(age.inMinutes);
  if (age.inDays < 1) return l.cameraAgeHours(age.inHours);
  return l.cameraAgeDays(age.inDays);
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
    _start();
  }

  /// Pings now, and every [PresencePinger.every] from now.
  void _start() {
    _timer?.cancel();
    widget.live?.ping().ignore();
    _timer = Timer.periodic(widget.every, (_) {
      widget.live?.ping().ignore();
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(PresencePinger old) {
    super.didUpdateWidget(old);
    // Another live sync, or another interval: start over with it.
    if (old.live != widget.live || old.every != widget.every) _start();
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
