import 'package:flutter/material.dart';

import 'auth/roles_service.dart';
import 'cloud/cloud_sync.dart';

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([roles, ?sync]),
      builder: (context, _) {
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
        final style = theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        Widget part(String key, String label, (String, String) status) =>
            Tooltip(
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
            part('api', '🔌 API', api),
            part('aws', '☁️ AWS', aws),
            part('oidc', '🔑 OIDC', oidc),
          ],
        );
      },
    );
  }

  /// A setting's status from what the auth API reports ([api]; null when
  /// it didn't) and this build's own ([app]). Null when both have it.
  static (String, String)? _setting(
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
