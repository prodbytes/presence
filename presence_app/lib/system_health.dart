import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import 'auth/roles_service.dart';
import 'cloud/cloud_sync.dart';
import 'events.dart';
import 'theme.dart';

/// One check's status: its emoji and what it means (the tooltip).
typedef HealthPart = (String, String);

/// The three checks at one moment: the auth API, AWS and OIDC.
typedef HealthStatus = ({HealthPart api, HealthPart aws, HealthPart oidc});

/// Whether a check failed: ❌, or ⚠️ (set on one side only).
bool healthPartFailed(HealthPart part) => part.$1 == '❌' || part.$1 == '⚠️';

/// One quiet line for the settings panel: whether the auth API answered,
/// and whether cloud sync (AWS) and sign-in (OIDC) are set up. For AWS and
/// OIDC, the auth API says whether its expected settings are set
/// ([RolesService.apiSettings]), and that's checked against this build's
/// own: ⚠️ when they disagree. Each part explains itself in a tooltip.
class SystemHealth extends StatelessWidget {
  SystemHealth({super.key, required this.roles, this.sync, bool? oidcClient})
    : oidcClient = oidcClient ?? hasOidcClient;

  final RolesService roles;

  /// Null when cloud sync isn't configured: events stay on this device.
  final CloudSync? sync;

  final bool oidcClient;

  /// The checks as they stand now.
  static HealthStatus statusOf(
    RolesService roles,
    CloudSync? sync, {
    required bool oidcClient,
  }) {
    final api = switch (roles.mode) {
      null => ('⏳', 'Auth API: checking'),
      _ when roles.apiError != null => (
        '❌',
        'Auth API: unreachable (${roles.apiError})',
      ),
      final mode => ('✅', 'Auth API: answered (${mode.name} mode)'),
    };
    final settings = roles.apiSettings;
    final aws = switch (_setting(
      'AWS',
      api: settings.aws,
      app: sync != null,
      off: 'events stay on this device',
    )) {
      final status? => status,
      // Set on both sides: how the sync is going.
      _ => switch (sync?.state) {
        CloudSyncState.error => (
          '❌',
          'AWS: sync failed (${sync!.error ?? 'unknown error'})',
        ),
        CloudSyncState.syncing => ('🔄', 'AWS: syncing'),
        CloudSyncState.synced => ('✅', 'AWS: synced'),
        _ => ('✅', 'AWS: set; syncs once signed in'),
      },
    };
    final oidc =
        _setting(
          'OIDC',
          api: settings.oidc,
          app: oidcClient,
          off: 'sign-in is off',
        ) ??
        ('✅', 'OIDC: Google sign-in set');
    return (api: api, aws: aws, oidc: oidc);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([roles, ?sync]),
      builder: (context, _) {
        final status = statusOf(roles, sync, oidcClient: oidcClient);
        final style = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        Widget part(String key, String label, HealthPart status) => Tooltip(
          message: status.$2,
          child: Text(
            '$label ${status.$1}',
            key: Key('health-$key'),
            style: style,
          ),
        );
        return Wrap(
          key: const Key('system-health'),
          alignment: WrapAlignment.center,
          spacing: 12,
          children: [
            part('api', '🔌 API', status.api),
            part('aws', '☁️ AWS', status.aws),
            part('oidc', '🔑 OIDC', status.oidc),
          ],
        );
      },
    );
  }

  /// A setting's status from what the auth API reports ([api]; null when
  /// it didn't) and this build's own ([app]). Null when both have it.
  static HealthPart? _setting(
    String name, {
    required bool? api,
    required bool app,
    required String off,
  }) => switch ((api, app)) {
    (true, true) || (null, true) => null,
    (false, false) => ('⚪', '$name: not set; $off'),
    (null, false) => ('⚪', '$name: not set in this build; $off'),
    (true, false) => (
      '⚠️',
      '$name: set in the auth API but not in this build; $off',
    ),
    (false, true) => ('⚠️', '$name: set in this build but not in the auth API'),
  };
}

/// One run of the health panel's checks.
class HealthCheck {
  const HealthCheck(this.time, this.status);

  final DateTime time;
  final HealthStatus status;

  /// Any of the checks failed ([healthPartFailed]).
  bool get failed =>
      [status.api, status.aws, status.oidc].any(healthPartFailed);
}

/// The health panel's latest checks, in memory, so they outlast the Log
/// tab being closed. Starts empty at every launch.
class HealthHistory extends ChangeNotifier {
  HealthHistory({this.capacity = 120});

  /// The app's history, which the Log tab's panel writes to.
  static final HealthHistory instance = HealthHistory();

  /// How many checks are kept (an hour, at one every 30 s).
  final int capacity;

  final _checks = ListQueue<HealthCheck>();

  /// Oldest first.
  List<HealthCheck> get checks => List.unmodifiable(_checks);

  void add(HealthCheck check) {
    _checks.addLast(check);
    while (_checks.length > capacity) {
      _checks.removeFirst();
    }
    notifyListeners();
  }
}

String _time(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// The Log tab's health panel: the [SystemHealth] line in a card, with
/// when it was last checked, and the latest checks as a row of bricks
/// ([HealthHistory]): green when all passed, red when any failed; tap one
/// for its details. It asks the auth API again ([RolesService.checkApi])
/// when it opens and every [interval] while it's shown, then records the
/// checks; AWS shows the cloud sync's latest pass, which runs on its own.
class HealthPanel extends StatefulWidget {
  HealthPanel({
    super.key,
    required this.roles,
    this.sync,
    this.events,
    this.userId,
    this.deviceId,
    bool? oidcClient,
    HealthHistory? history,
    this.interval = const Duration(seconds: 30),
  }) : oidcClient = oidcClient ?? hasOidcClient,
       history = history ?? HealthHistory.instance;

  final RolesService roles;
  final CloudSync? sync;
  final bool oidcClient;
  final HealthHistory history;

  /// The event history, whose distinct devices the panel counts; no count
  /// without it.
  final EventLog? events;

  /// The signed-in user's ID (null signed out): only their events count,
  /// as in the Events tab.
  final String? userId;

  /// This device's ID, for events not saved yet (they have none).
  final String? deviceId;

  /// How many devices recorded [events]: distinct device IDs, with events
  /// not saved yet counted as [deviceId]'s.
  static int devicesIn(Iterable<AppEvent> events, {String? deviceId}) =>
      {for (final e in events) ?(e.deviceId ?? deviceId)}.length;

  /// How often the checks run.
  final Duration interval;

  @override
  State<HealthPanel> createState() => _HealthPanelState();
}

class _HealthPanelState extends State<HealthPanel> {
  Timer? _timer;
  bool _disposed = false;

  /// The brick tapped, whose details show under the bricks.
  HealthCheck? _selected;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(widget.interval, (_) => _check());
  }

  Future<void> _check() async {
    await widget.roles.checkApi();
    // Before the start check, there's nothing to record yet.
    if (_disposed || widget.roles.mode == null) return;
    widget.history.add(
      HealthCheck(
        widget.roles.apiCheckedAt ?? DateTime.now(),
        SystemHealth.statusOf(
          widget.roles,
          widget.sync,
          oidcClient: widget.oidcClient,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Card(
      key: const Key('health-panel'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Health', style: theme.textTheme.titleSmall),
                ),
                ListenableBuilder(
                  listenable: widget.roles,
                  builder: (context, _) => Text(
                    switch (widget.roles.apiCheckedAt) {
                      final at? => 'Last update ${_time(at)}',
                      null => 'Checking…',
                    },
                    key: const Key('health-checked'),
                    style: small,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SystemHealth(
              roles: widget.roles,
              sync: widget.sync,
              oidcClient: widget.oidcClient,
            ),
            if (widget.events case final events?)
              ListenableBuilder(
                listenable: events,
                builder: (context, _) {
                  final n = HealthPanel.devicesIn(
                    EventTimeline.ofUser(events.events, widget.userId),
                    deviceId: widget.deviceId,
                  );
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '📱 Devices $n',
                      key: const Key('health-devices'),
                      semanticsLabel:
                          '$n ${n == 1 ? 'device' : 'devices'} in the events',
                    ),
                  );
                },
              ),
            ListenableBuilder(
              listenable: widget.history,
              builder: (context, _) => _bricks(theme, small),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bricks(ThemeData theme, TextStyle? small) {
    final checks = widget.history.checks;
    if (checks.isEmpty) return const SizedBox.shrink();
    final selected = checks.contains(_selected) ? _selected : null;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            key: const Key('health-history'),
            spacing: 2,
            runSpacing: 2,
            children: [
              for (final (i, check) in checks.indexed)
                Semantics(
                  button: true,
                  label:
                      '${_time(check.time)}: '
                      '${check.failed ? 'failed' : 'all passed'}',
                  child: GestureDetector(
                    key: Key('health-brick-$i'),
                    onTap: () => setState(
                      () =>
                          _selected = identical(check, selected) ? null : check,
                    ),
                    child: Container(
                      width: 8,
                      height: 14,
                      decoration: BoxDecoration(
                        color: check.failed
                            ? theme.colorScheme.error
                            : Gruvbox.green,
                        borderRadius: BorderRadius.circular(2),
                        border: identical(check, selected)
                            ? Border.all(
                                color: theme.colorScheme.onSurface,
                                width: 1.5,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: SelectableText(
                [
                  '${_time(selected.time)} · '
                      '${selected.failed ? 'failed' : 'all passed'}',
                  for (final part in [
                    selected.status.api,
                    selected.status.aws,
                    selected.status.oidc,
                  ])
                    '${part.$1} ${part.$2}',
                ].join('\n'),
                key: const Key('health-detail'),
                style: small,
              ),
            ),
        ],
      ),
    );
  }
}
