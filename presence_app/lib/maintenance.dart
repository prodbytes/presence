import 'package:flutter/material.dart';

import 'auth/roles_service.dart';

/// Maintenance mode (`RolesService.inMaintenance`, rbacr's flag for
/// Presence's system) over the whole app: while it's on, the signed-in user
/// sees [MaintenanceScreen] instead of the app, whose screens (and any
/// dialog or sheet open on them) close; they come back fresh when it's
/// switched off. Nobody gets past it, admins included: rbacr gives nobody
/// a role in the system meanwhile. Roots switch it in rbacr.
class MaintenanceGate extends StatelessWidget {
  const MaintenanceGate({super.key, required this.roles, required this.child});

  final RolesService roles;

  /// The app: MaterialApp's navigator.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: roles,
      builder: (context, app) =>
          roles.inMaintenance ? const MaintenanceScreen() : app!,
      child: child,
    );
  }
}

/// All the app shows in maintenance mode: a sorry message. Nothing else:
/// no tabs, camera or sign-in.
class MaintenanceScreen extends StatelessWidget {
  const MaintenanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const Key('maintenance'),
      color: scheme.surface,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.construction, size: 56, color: scheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Sorry, Presence is down for maintenance.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'We\'ll be back soon. This page comes back on its own.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
