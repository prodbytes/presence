import 'package:flutter/material.dart';

import 'auth/roles_service.dart';
import 'theme.dart';

/// Maintenance mode (`RolesService.maintenance`) over the whole app: while
/// it's on, everyone but admins sees [MaintenanceScreen] instead of the
/// app, whose screens (and any dialog or sheet open on them) close; they
/// come back fresh when it's switched off. Admins keep the app, under a
/// strip saying the system is in maintenance, so they can switch it off on
/// the Admin tab.
class MaintenanceGate extends StatelessWidget {
  const MaintenanceGate({super.key, required this.roles, required this.child});

  final RolesService roles;

  /// The app: MaterialApp's navigator.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: roles,
      builder: (context, app) {
        if (roles.inMaintenance) {
          return MaintenanceScreen(message: roles.maintenance.message);
        }
        if (!roles.maintenance.on) return app!;
        return Column(
          children: [
            Material(
              key: const Key('maintenance-strip'),
              color: Gruvbox.yellow,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.construction,
                        size: 18,
                        color: Gruvbox.bg0Hard,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Maintenance mode is on: only admins see the app.',
                          style: const TextStyle(color: Gruvbox.bg0Hard),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: app!,
              ),
            ),
          ],
        );
      },
      child: child,
    );
  }
}

/// All the app shows in maintenance mode: a sorry message, and the
/// admin's [message] when they left one. Nothing else: no tabs, camera or
/// sign-in.
class MaintenanceScreen extends StatelessWidget {
  const MaintenanceScreen({super.key, this.message = ''});

  final String message;

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
                  if (message.trim().isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      message.trim(),
                      key: const Key('maintenance-message'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
