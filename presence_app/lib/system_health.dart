import 'package:flutter/material.dart';

import 'auth/roles_service.dart';
import 'cloud/cloud_sync.dart';

/// One quiet line for the settings panel: whether the auth API answered,
/// whether cloud sync (AWS) is set up and working, and whether sign-in
/// (OIDC) is configured. Each part explains itself in a tooltip.
class SystemHealth extends StatelessWidget {
  SystemHealth({
    super.key,
    required this.roles,
    this.sync,
    bool? oidcClient,
  }) : oidcClient = oidcClient ?? hasOidcClient;

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
        final aws = switch (sync?.state) {
          null => ('⚪', 'AWS: not configured; events stay on this device'),
          CloudSyncState.error => (
            '❌',
            'AWS: sync failed (${sync!.error ?? 'unknown error'})',
          ),
          CloudSyncState.syncing => ('🔄', 'AWS: syncing'),
          CloudSyncState.synced => ('✅', 'AWS: synced'),
          CloudSyncState.off => ('✅', 'AWS: configured; syncs once signed in'),
        };
        final oidc = oidcClient
            ? ('✅', 'OIDC: Google sign-in configured')
            : ('⚪', 'OIDC: not configured; sign-in is off');
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
}
