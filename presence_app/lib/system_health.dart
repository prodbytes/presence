import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import 'auth/roles_service.dart';
import 'cloud/cloud_sync.dart';
import 'events.dart';
import 'status_pill.dart';
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

/// Over the camera, while a health check fails: a [StatusPill] with only
/// a warning icon, in the error color. Its tooltip and screen-reader label
/// name the [failed] checks; tapping it calls [onTap].
class HealthWarningPill extends StatelessWidget {
  const HealthWarningPill({super.key, required this.failed, this.onTap});

  /// The failed checks' explanations ([failedChecks]).
  final List<String> failed;

  /// Where tapping it goes: the checks' details.
  final VoidCallback? onTap;

  /// The explanations of the checks that fail now ([healthPartFailed]);
  /// empty while every check passes or is still running.
  static List<String> failedChecks(
    RolesService roles,
    CloudSync? sync, {
    bool? oidcClient,
  }) {
    final status = SystemHealth.statusOf(
      roles,
      sync,
      oidcClient: oidcClient ?? hasOidcClient,
    );
    return [
      for (final part in [status.api, status.aws, status.oidc])
        if (healthPartFailed(part)) part.$2,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final pill = StatusPill(
      key: const Key('health-warning'),
      leading: Icon(
        Icons.warning_amber_rounded,
        size: 18,
        color: Theme.of(context).colorScheme.error,
      ),
      semantics: [
        'Health check failed',
        ...failed,
        if (onTap != null) 'Tap for details.',
      ].join('\n'),
    );
    if (onTap == null) return pill;
    return GestureDetector(onTap: onTap, child: pill);
  }
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

/// What a check's emoji means, short, for its pill, and the pill's color.
(String, Color) _tone(HealthPart part, ColorScheme scheme) => switch (part.$1) {
  '✅' => ('OK', Gruvbox.green),
  '❌' => ('Failed', scheme.error),
  '⚠️' => ('Mismatch', Gruvbox.yellow),
  '⏳' => ('Checking', Gruvbox.blue),
  '🔄' => ('Syncing', Gruvbox.blue),
  _ => ('Off', Gruvbox.gray),
};

/// A check's explanation without its name ("Auth API: answered" →
/// "answered"), for under the name on its card.
String _detail(HealthPart part) {
  final i = part.$2.indexOf(': ');
  final text = i < 0 ? part.$2 : part.$2.substring(i + 2);
  return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

/// The checks the panel shows, in order: key, emoji, name, and the part of
/// a [HealthStatus] it is.
final List<(String, String, String, HealthPart Function(HealthStatus))>
_checks = [
  ('api', '🔌', 'Auth API', (s) => s.api),
  ('aws', '☁️', 'AWS', (s) => s.aws),
  ('oidc', '🔑', 'OIDC', (s) => s.oidc),
];

/// The Log tab's health panel: a card per check (the auth API, AWS, OIDC)
/// with its status in a colored pill, a card with the number of devices in
/// the events, and a timeline of the latest checks ([HealthHistory]): a
/// colored cell per check and run, newest on the right, with the time
/// every 2 minutes, scrolling sideways; tap a run for its details. It asks
/// the auth API again ([RolesService.checkApi]) when it opens and every
/// [interval] while it's shown, then records the checks; AWS shows the
/// cloud sync's latest pass, which runs on its own.
class HealthPanel extends StatefulWidget {
  HealthPanel({
    super.key,
    required this.roles,
    this.sync,
    this.events,
    this.profileId,
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

  /// The signed-in account's profile (null signed out): only its events
  /// count, as in the Events tab.
  final String? profileId;

  /// This device's ID, for events not saved yet (they have none).
  final String? deviceId;

  /// How many devices recorded [events]: distinct device IDs, with events
  /// not saved yet counted as [deviceId]'s.
  static int devicesIn(Iterable<AppEvent> events, {String? deviceId}) =>
      {for (final e in events) ?(e.deviceId ?? deviceId)}.length;

  /// How often the checks run.
  final Duration interval;

  /// Room each run takes on the timeline, and its cells' size.
  static const double runWidth = 14;
  static const Size cellSize = Size(10, 14);

  @override
  State<HealthPanel> createState() => _HealthPanelState();
}

class _HealthPanelState extends State<HealthPanel> {
  Timer? _timer;
  bool _disposed = false;

  /// The run tapped on the timeline, whose details show under it.
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
    return Padding(
      key: const Key('health-panel'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Health', style: theme.textTheme.titleMedium),
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
          ListenableBuilder(
            listenable: Listenable.merge([
              widget.roles,
              ?widget.sync,
              ?widget.events,
            ]),
            builder: (context, _) => _cards(theme, small),
          ),
          ListenableBuilder(
            listenable: widget.history,
            builder: (context, _) => _timeline(theme, small),
          ),
        ],
      ),
    );
  }

  /// A card per check, and one for the devices: four across when there's
  /// room, otherwise two, each row's cards as tall as the tallest.
  Widget _cards(ThemeData theme, TextStyle? small) => LayoutBuilder(
    builder: (context, constraints) {
      final count = _checks.length + (widget.events == null ? 0 : 1);
      final columns = constraints.maxWidth >= 720 ? count : 2;
      final width = (constraints.maxWidth - 8 * (columns - 1)) / columns;
      return _grid(
        _cardList(theme, pillBeside: width >= _HealthCard.pillBesideFrom),
        columns,
      );
    },
  );

  List<Widget> _cardList(ThemeData theme, {required bool pillBeside}) {
    final status = SystemHealth.statusOf(
      widget.roles,
      widget.sync,
      oidcClient: widget.oidcClient,
    );
    return <Widget>[
      for (final (key, emoji, name, part) in _checks)
        _HealthCard(
          key: Key('health-$key'),
          emoji: emoji,
          title: name,
          tooltip: part(status).$2,
          detail: _detail(part(status)),
          pillBeside: pillBeside,
          pill: switch (_tone(part(status), theme.colorScheme)) {
            (final label, final color) => _Pill(
              key: Key('health-$key-status'),
              text: label,
              color: color,
            ),
          },
        ),
      if (widget.events case final events?)
        _devicesCard(events, theme, pillBeside: pillBeside),
    ];
  }

  /// [cards] in rows of [columns], each row's cards as tall as the tallest.
  static Widget _grid(List<Widget> cards, int columns) => Column(
    spacing: 8,
    children: [
      for (var i = 0; i < cards.length; i += columns)
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              for (var j = i; j < i + columns; j++)
                Expanded(
                  child: j < cards.length ? cards[j] : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
    ],
  );

  Widget _devicesCard(
    EventLog events,
    ThemeData theme, {
    required bool pillBeside,
  }) {
    final n = HealthPanel.devicesIn(
      EventTimeline.ofProfile(events.events, widget.profileId),
      deviceId: widget.deviceId,
    );
    final what = widget.profileId == null
        ? 'In the events on this device'
        : 'In the profile\'s events';
    return Semantics(
      label: '$n ${n == 1 ? 'device' : 'devices'} in the events',
      excludeSemantics: true,
      child: _HealthCard(
        key: const Key('health-devices'),
        emoji: '📱',
        title: 'Devices',
        tooltip: '$what, here and synced from the cloud',
        detail: what,
        pillBeside: pillBeside,
        pill: _Pill(
          key: const Key('health-devices-count'),
          text: '$n',
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  /// The latest runs: a row per check, a column per run, newest on the
  /// right and scrolled to, with the time under the first run of every 2
  /// minutes.
  Widget _timeline(ThemeData theme, TextStyle? small) {
    final checks = widget.history.checks;
    if (checks.isEmpty) return const SizedBox.shrink();
    final selected = checks.contains(_selected) ? _selected : null;
    const cell = HealthPanel.cellSize;
    const gap = 3.0;
    const labelHeight = 18.0;
    final cellsHeight = _checks.length * (cell.height + gap);
    final every = widget.interval.inSeconds;
    return Card(
      key: const Key('health-timeline'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Timeline', style: theme.textTheme.titleSmall),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    '${checks.length} ${checks.length == 1 ? 'check' : 'checks'}'
                    ' · every ${every >= 60 ? '${every ~/ 60} min' : '$every s'}',
                    style: small,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: cellsHeight + labelHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // The checks' names, each beside its row.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (_, emoji, name, _) in _checks)
                        Container(
                          height: cell.height,
                          margin: const EdgeInsets.only(bottom: gap),
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '$emoji ${name == 'Auth API' ? 'API' : name}',
                            style: small?.copyWith(height: 1),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ListView.builder(
                      key: const Key('health-history'),
                      scrollDirection: Axis.horizontal,
                      // Starts at the newest, on the right.
                      reverse: true,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: checks.length,
                      itemBuilder: (context, j) {
                        final i = checks.length - 1 - j;
                        final check = checks[i];
                        return _run(
                          i,
                          check,
                          tick:
                              i == 0 ||
                              _bucket(checks[i - 1]) != _bucket(check),
                          selected: identical(check, selected),
                          cellsHeight: cellsHeight,
                          gap: gap,
                          theme: theme,
                          small: small,
                          onTap: () => setState(
                            () => _selected = identical(check, selected)
                                ? null
                                : check,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  [
                    '${_time(selected.time)} · '
                        '${selected.failed ? 'failed' : 'all passed'}',
                    for (final (_, _, _, part) in _checks)
                      '${part(selected.status).$1} ${part(selected.status).$2}',
                  ].join('\n'),
                  key: const Key('health-detail'),
                  style: small,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Which 2-minute stretch [check] ran in: the timeline labels the first
  /// run of each, so labels stay put as runs are added.
  static int _bucket(HealthCheck check) =>
      check.time.millisecondsSinceEpoch ~/
      const Duration(minutes: 2).inMilliseconds;

  Widget _run(
    int i,
    HealthCheck check, {
    required bool tick,
    required bool selected,
    required double cellsHeight,
    required double gap,
    required ThemeData theme,
    required TextStyle? small,
    required VoidCallback onTap,
  }) {
    const cell = HealthPanel.cellSize;
    const width = HealthPanel.runWidth;
    final t = check.time;
    String two(int n) => n.toString().padLeft(2, '0');
    return Semantics(
      button: true,
      label: '${_time(t)}: ${check.failed ? 'failed' : 'all passed'}',
      child: GestureDetector(
        key: Key('health-brick-$i'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                children: [
                  for (final (key, _, _, part) in _checks)
                    Container(
                      key: Key('health-cell-$i-$key'),
                      width: cell.width,
                      height: cell.height,
                      margin: EdgeInsets.only(bottom: gap),
                      decoration: BoxDecoration(
                        color: _tone(part(check.status), theme.colorScheme).$2,
                        borderRadius: BorderRadius.circular(2),
                        border: selected
                            ? Border.all(
                                color: theme.colorScheme.onSurface,
                                width: 1.5,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
              if (tick)
                Positioned(
                  // Centered on the run's cells.
                  left: cell.width / 2 - 20,
                  width: 40,
                  top: cellsHeight,
                  child: Column(
                    children: [
                      Container(
                        width: 1,
                        height: 4,
                        color: theme.colorScheme.outline,
                      ),
                      Text(
                        '${two(t.hour)}:${two(t.minute)}',
                        style: small?.copyWith(fontSize: 10, height: 1.2),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the health panel's cards: an emoji, a name, a [pill] on the
/// right, and a line of [detail] under them ([tooltip] in full).
class _HealthCard extends StatelessWidget {
  const _HealthCard({
    super.key,
    required this.emoji,
    required this.title,
    required this.pill,
    required this.detail,
    required this.tooltip,
    required this.pillBeside,
  });

  /// The card width from which the pill fits beside the name.
  static const double pillBesideFrom = 200;

  final String emoji;
  final String title;
  final Widget pill;
  final String detail;
  final String tooltip;

  /// The [pill] beside the name ([pillBesideFrom]), or under it.
  final bool pillBeside;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              Row(
                spacing: 8,
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 18)),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (pillBeside) pill,
                ],
              ),
              // Narrow (two cards across a phone): the pill goes under the
              // name, so the name keeps its room.
              if (!pillBeside) pill,
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded label in [color]: a check's status, or the devices' count.
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: color.withValues(alpha: 0.6)),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}
