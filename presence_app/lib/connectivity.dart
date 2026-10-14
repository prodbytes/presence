
import 'package:flutter/material.dart';

import 'auth/roles_service.dart';
import 'cloud/cloud_sync.dart';
import 'cloud/live_sync.dart';
import 'device_presence.dart';
import 'l10n/l10n.dart';
import 'system_health.dart';

/// This device's connectivity, from the health checks
/// ([SystemHealth.statusOf]): whether the auth API answers, how cloud sync
/// is going, and whether live sync is connected. [level] is the worst of
/// the three, in [DevicePresence]'s colors: [PresenceLevel.live] (green)
/// only when all is well and live sync is connected, so other devices see
/// this one live; [PresenceLevel.recent] (amber) when it's degraded (still
/// checking, connecting, idle between scheduled connections, or live sync
/// not set up or off); [PresenceLevel.old] (red) when a check failed.
class Connectivity {
  const Connectivity({
    required this.level,
    required this.headline,
    required this.api,
    required this.aws,
    required this.live,
    this.l10n,
  });

  /// The language [headline] is in; English when null.
  final AppLocalizations? l10n;

  /// Green, amber or red.
  final PresenceLevel level;

  /// Why, in a few words: the check that decides [level].
  final String headline;

  /// The checks, as the health panel words them.
  final HealthPart api;
  final HealthPart aws;
  final HealthPart live;

  /// The connectivity as it stands now. [live] defaults to [sync]'s. Worded
  /// in [l], English by default.
  factory Connectivity.of(
    RolesService roles,
    CloudSync? sync, {
    LiveSync? live,
    bool? oidcClient,
    AppLocalizations? l,
  }) {
    final t = l ?? lookupAppLocalizations(const Locale('en'));
    final status = SystemHealth.statusOf(
      roles,
      sync,
      oidcClient: oidcClient ?? hasOidcClient,
      l: t,
    );
    final liveSync = live ?? sync?.live;
    final livePart = SystemHealth.liveStatusOf(liveSync, t);
    final checks = <(PresenceLevel, String)>[
      switch (status.api.$1) {
        '✅' => (PresenceLevel.live, t.connectivityOnline),
        '❌' => (PresenceLevel.old, t.connectivityOffline),
        _ => (PresenceLevel.recent, t.connectivityChecking),
      },
      switch (status.aws.$1) {
        // A pass runs every 15 s: syncing is the normal course, not a
        // reason to turn amber and back each time.
        '✅' || '🔄' when sync?.premium == false => (
          PresenceLevel.live,
          t.connectivityFree,
        ),
        '✅' || '🔄' => (PresenceLevel.live, t.connectivityCloudOn),
        '❌' => (PresenceLevel.old, t.connectivityCloudFailed),
        '⚠️' => (PresenceLevel.recent, t.connectivityCloudOneSide),
        _ => (PresenceLevel.recent, t.connectivityCloudNotSet),
      },
      switch (livePart.$1) {
        '✅' when liveSync?.state == LiveSyncState.connected => (
          PresenceLevel.live,
          t.connectivityLiveConnected,
        ),
        '✅' => (PresenceLevel.recent, t.connectivityLiveOnceSynced),
        '⏳' => (PresenceLevel.recent, t.connectivityLiveConnecting),
        '💤' => (
          PresenceLevel.recent,
          t.connectivityLiveIdle(
            SystemHealth.formatNextIn(liveSync?.untilNext),
          ),
        ),
        '❌' => (PresenceLevel.old, t.connectivityLiveFailed),
        _ when liveSync == null || !liveSync.enabled => (
          PresenceLevel.recent,
          t.connectivityLiveNotSet,
        ),
        _ => (PresenceLevel.recent, t.connectivityLiveOff),
      },
    ];
    // The worst check decides; the first of equals (API, then cloud
    // sync, then live sync) says why.
    final (level, headline) = checks.reduce(
      (worst, check) => check.$1.index > worst.$1.index ? check : worst,
    );
    return Connectivity(
      level: level,
      headline: level == PresenceLevel.live ? t.connectivityAllGood : headline,
      api: status.api,
      aws: status.aws,
      live: livePart,
      l10n: l,
    );
  }

  /// This device's presence dot in the devices list: the same color, and
  /// the headline as its reason.
  DevicePresence get presence => DevicePresence(
    level,
    (l10n ?? lookupAppLocalizations(const Locale('en'))).connectivityThisDevice(
      headline,
    ),
  );

  /// The checks' lines, emoji first, for the details.
  List<String> get details => [
    for (final part in [api, aws, live]) '${part.$1} ${part.$2}',
  ];
}
