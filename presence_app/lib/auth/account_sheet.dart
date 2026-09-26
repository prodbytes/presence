import 'package:flutter/material.dart';

import '../cloud/cloud_sync.dart';
import 'auth_service.dart';

/// The app bar's account button: the user's avatar when signed in, a person
/// icon otherwise. Opens [AccountSheet].
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, required this.auth, this.sync});

  final AuthService auth;
  final CloudSync? sync;

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
            builder: (_) => AccountSheet(auth: auth, sync: sync),
          ),
        );
      },
    );
  }
}

/// The app bar's sign-in control while signed out: "Sign in with Google"
/// (Google's own button on web). Nothing while the launch check runs; if
/// sign-in isn't set up, a person icon whose sheet says so.
class SignInAction extends StatelessWidget {
  const SignInAction({super.key, required this.auth});

  final AuthService auth;

  @override
  Widget build(BuildContext context) {
    if (auth.checking) return const SizedBox.shrink();
    if (!auth.available) return AccountButton(auth: auth);
    return Center(
      child:
          auth.buildSignInButton() ??
          FilledButton.icon(
            key: const Key('google-sign-in'),
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Sign in with Google'),
            onPressed: auth.signIn,
          ),
    );
  }
}

/// Sign in with Google, or show who is signed in and offer sign-out.
class AccountSheet extends StatelessWidget {
  const AccountSheet({super.key, required this.auth, this.sync});

  final AuthService auth;

  /// Cloud uploads, when configured: their status shows under the email.
  final CloudSync? sync;

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
                  if (sync case final sync?) ...[
                    const SizedBox(height: 8),
                    CloudSyncStatus(sync: sync),
                  ],
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

/// One line about cloud uploads: syncing, synced (and how many), or why not.
class CloudSyncStatus extends StatelessWidget {
  const CloudSyncStatus({super.key, required this.sync});

  final CloudSync sync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final (icon, text, color) = switch (sync.state) {
          CloudSyncState.off => (
            Icons.cloud_off_outlined,
            'Cloud backup is off',
            scheme.onSurfaceVariant,
          ),
          CloudSyncState.syncing => (
            Icons.cloud_upload_outlined,
            'Uploading…',
            scheme.onSurfaceVariant,
          ),
          CloudSyncState.synced => (
            Icons.cloud_done_outlined,
            sync.uploaded == 0
                ? 'Clips and events are backed up'
                : 'Backed up (${sync.uploaded} uploaded)',
            scheme.onSurfaceVariant,
          ),
          CloudSyncState.error => (
            Icons.cloud_off_outlined,
            sync.error ?? 'Upload failed',
            scheme.error,
          ),
        };
        return Row(
          key: const Key('cloud-sync-status'),
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Icon(icon, size: 18, color: color),
            Flexible(
              child: Text(text, style: TextStyle(color: color)),
            ),
          ],
        );
      },
    );
  }
}
