import 'dart:async';

import 'package:flutter/material.dart';

import 'auth/roles_service.dart';
import 'cloud/cloud_sync.dart';
import 'cloud/live_sync.dart';
import 'device_presence.dart';
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
  });

  /// Green, amber or red.
  final PresenceLevel level;

  /// Why, in a few words: the check that decides [level].
  final String headline;

  /// The checks, as the health panel words them.
  final HealthPart api;
  final HealthPart aws;
  final HealthPart live;

  /// The connectivity as it stands now. [live] defaults to [sync]'s.
  factory Connectivity.of(
    RolesService roles,
    CloudSync? sync, {
    LiveSync? live,
    bool? oidcClient,
  }) {
    final status = SystemHealth.statusOf(
      roles,
      sync,
      oidcClient: oidcClient ?? hasOidcClient,
    );
    final liveSync = live ?? sync?.live;
    final livePart = SystemHealth.liveStatusOf(liveSync);
    final checks = <(PresenceLevel, String)>[
      switch (status.api.$1) {
        '✅' => (PresenceLevel.live, 'Online'),
        '❌' => (PresenceLevel.old, "Offline: can't reach the server"),
        _ => (PresenceLevel.recent, 'Checking the connection…'),
      },
      switch (status.aws.$1) {
        // A pass runs every 15 s: syncing is the normal course, not a
        // reason to turn amber and back each time.
        '✅' || '🔄' when sync?.premium == false => (
          PresenceLevel.live,
          'Free: devices sync over live sync',
        ),
        '✅' || '🔄' => (PresenceLevel.live, 'Cloud sync on'),
        '❌' => (PresenceLevel.old, 'Cloud sync failed'),
        '⚠️' => (PresenceLevel.recent, 'Cloud sync is set up on one side only'),
        _ => (PresenceLevel.recent, "Cloud sync isn't set up in this build"),
      },
      switch (livePart.$1) {
        '✅' when liveSync?.state == LiveSyncState.connected => (
          PresenceLevel.live,
          'Live sync connected',
        ),
        '✅' => (PresenceLevel.recent, 'Live sync connects once synced'),
        '⏳' => (PresenceLevel.recent, 'Connecting to live sync…'),
        '💤' => (
          PresenceLevel.recent,
          'Live sync idle · next in '
              '${SystemHealth.formatNextIn(liveSync?.untilNext)}',
        ),
        '❌' => (PresenceLevel.old, 'Live sync failed'),
        _ when liveSync == null || !liveSync.enabled => (
          PresenceLevel.recent,
          "Live sync isn't set up in this build",
        ),
        _ => (PresenceLevel.recent, 'Live sync is off'),
      },
    ];
    // The worst check decides; the first of equals (API, then cloud
    // sync, then live sync) says why.
    final (level, headline) = checks.reduce(
      (worst, check) => check.$1.index > worst.$1.index ? check : worst,
    );
    return Connectivity(
      level: level,
      headline: level == PresenceLevel.live
          ? 'Online · live sync connected'
          : headline,
      api: status.api,
      aws: status.aws,
      live: livePart,
    );
  }

  /// This device's presence dot in the devices list: the same color, and
  /// the headline as its reason.
  DevicePresence get presence =>
      DevicePresence(level, 'This device — $headline');

  /// The checks' lines, emoji first, for the details.
  List<String> get details => [
    for (final part in [api, aws, live]) '${part.$1} ${part.$2}',
  ];
}

/// At the top of the account sheet: this device's connectivity
/// ([Connectivity]) as a dot in its color and its headline; tap it for
/// each check's details. It asks the auth API again
/// ([RolesService.checkApi]) when it shows and every [HealthPanel]
/// interval while it does, and redraws every second while live sync is
/// idle, so the countdown to its next connection runs.
class ConnectivityIndicator extends StatefulWidget {
  const ConnectivityIndicator({
    super.key,
    required this.roles,
    this.sync,
    this.live,
    this.oidcClient,
    this.interval,
  });

  final RolesService roles;

  /// Null when cloud sync isn't in this build.
  final CloudSync? sync;

  /// Live sync; [sync]'s by default.
  final LiveSync? live;

  final bool? oidcClient;

  /// How often the auth API is asked again; [HealthPanel.intervalFor] the
  /// mode by default.
  final Duration? interval;

  @override
  State<ConnectivityIndicator> createState() => _ConnectivityIndicatorState();
}

class _ConnectivityIndicatorState extends State<ConnectivityIndicator> {
  bool _expanded = false;
  Timer? _check;
  bool _disposed = false;

  LiveSync? get _live => widget.live ?? widget.sync?.live;

  late final Timer _tick = Timer.periodic(const Duration(seconds: 1), (_) {
    if (_live?.state == LiveSyncState.idle) setState(() {});
  });

  @override
  void initState() {
    super.initState();
    _tick;
    _checkApi();
  }

  Future<void> _checkApi() async {
    await widget.roles.checkApi();
    if (_disposed) return;
    _check = Timer(
      widget.interval ??
          HealthPanel.intervalFor(
            widget.roles.mode,
            oidcClient: widget.oidcClient ?? hasOidcClient,
          ),
      _checkApi,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _check?.cancel();
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.roles, ?widget.sync, ?_live]),
    builder: (context, _) => _build(
      context,
      Connectivity.of(
        widget.roles,
        widget.sync,
        live: _live,
        oidcClient: widget.oidcClient,
      ),
    ),
  );

  Widget _build(BuildContext context, Connectivity status) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = status.presence.color;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final label = [
      'Connectivity: ${status.headline}',
      ...status.details.map((line) => line.substring(line.indexOf(' ') + 1)),
    ].join('\n');
    return Container(
      key: const Key('connectivity'),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(
                  message: label,
                  child: Semantics(
                    key: const Key('connectivity-semantics'),
                    label: label,
                    button: true,
                    expanded: _expanded,
                    excludeSemantics: true,
                    child: Row(
                      spacing: 10,
                      children: [
                        Container(
                          key: const Key('connectivity-dot'),
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            status.headline,
                            key: const Key('connectivity-headline'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          _expanded ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_expanded)
                  Padding(
                    key: const Key('connectivity-details'),
                    padding: const EdgeInsets.only(top: 6, right: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: [
                        for (final line in status.details)
                          Text(line, style: small),
                        Text(
                          'Other devices see this one live only while live '
                          'sync is connected.',
                          style: small,
                        ),
                      ],
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
