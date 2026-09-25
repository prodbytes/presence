import 'package:flutter/material.dart';

import 'auth_service.dart';

/// The app bar's account button: the user's avatar when signed in, a person
/// icon otherwise. Opens [AccountSheet].
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final user = auth.user;
        return IconButton(
          key: const Key('account-button'),
          tooltip: user == null ? 'Sign in' : 'Signed in as ${user.identity}',
          icon: user == null
              ? const Icon(Icons.person)
              : UserAvatar(user: user, radius: 14),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            builder: (_) => AccountSheet(auth: auth),
          ),
        );
      },
    );
  }
}

/// Sign in with Google, or show who is signed in and offer sign-out.
class AccountSheet extends StatelessWidget {
  const AccountSheet({super.key, required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final user = auth.user;
        final error = auth.error;
        return SafeArea(
          child: Padding(
            key: const Key('account-sheet'),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!auth.available) ...[
                  Icon(
                    Icons.lock_outline,
                    size: 40,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    auth.unavailableReason ?? 'Sign-in is unavailable.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ] else if (user == null) ...[
                  Text(
                    'Sign in to Presence',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  auth.buildSignInButton() ??
                      FilledButton.icon(
                        key: const Key('google-sign-in'),
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in with Google'),
                        onPressed: auth.signIn,
                      ),
                ] else ...[
                  UserAvatar(user: user, radius: 32),
                  const SizedBox(height: 12),
                  if (user.name case final name?)
                    Text(name, style: theme.textTheme.titleMedium),
                  Text(
                    user.email,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const Key('sign-out'),
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                    // Close the sheet first: signing out swaps the whole
                    // app for the sign-in screen.
                    onPressed: () {
                      Navigator.of(context).pop();
                      auth.signOut();
                    },
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The user's photo, or their initial when there's none (or it fails).
class UserAvatar extends StatelessWidget {
  const UserAvatar({super.key, required this.user, required this.radius});

  final AuthUser user;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = user.label.characters.first.toUpperCase();
    final photo = user.photoUrl;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      foregroundImage: photo == null ? null : NetworkImage(photo),
      onForegroundImageError: photo == null ? null : (_, _) {},
      child: Text(initial, style: TextStyle(fontSize: radius * 0.9)),
    );
  }
}
