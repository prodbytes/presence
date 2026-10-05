import 'package:flutter/material.dart';

import '../cloud/cloud_sync.dart';
import '../events.dart';
import 'auth_service.dart';
import 'linked_accounts_sheet.dart';
import 'membership_client.dart';
import 'profile_client.dart';
import 'roles_service.dart';

/// The app bar's account button: the user's avatar when signed in, a person
/// icon otherwise. Opens [AccountSheet].
class AccountButton extends StatelessWidget {
  const AccountButton({
    super.key,
    required this.auth,
    this.sync,
    this.roles,
    this.profiles,
    this.log,
    this.deviceId,
  });

  final AuthService auth;
  final CloudSync? sync;

  /// With [profiles], the sheet offers Linked accounts.
  final RolesService? roles;
  final ProfileClient? profiles;

  /// The events the sheet's device list comes from, and this device's ID.
  final EventLog? log;
  final String? deviceId;

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
            // Room to scroll a long device list.
            isScrollControlled: true,
            builder: (_) => AccountSheet(
              auth: auth,
              sync: sync,
              roles: roles,
              profiles: profiles,
              log: log,
              deviceId: deviceId,
            ),
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

/// Sign in with Google, or show who is signed in, their profile and its
/// devices, and offer sign-out.
class AccountSheet extends StatelessWidget {
  const AccountSheet({
    super.key,
    required this.auth,
    this.sync,
    this.roles,
    this.profiles,
    this.log,
    this.deviceId,
  });

  final AuthService auth;

  /// Cloud uploads, when configured: their status shows under the email.
  final CloudSync? sync;

  /// With both, a Linked accounts button (see [LinkedAccountsSheet]).
  final RolesService? roles;
  final ProfileClient? profiles;

  /// The events whose device IDs list the profile's devices (see
  /// [profileDevices]), and this device's ID, listed first.
  final EventLog? log;
  final String? deviceId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([auth, ?roles, ?log]),
      builder: (context, _) {
        final user = auth.user;
        final error = auth.error;
        return SafeArea(
          child: SingleChildScrollView(
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
                    if (roles?.profile case final profile?) ...[
                      const SizedBox(height: 16),
                      ProfileDevices(
                        profile: profile,
                        devices: profileDevices(
                          log?.events ?? const [],
                          profileId: profile,
                          thisDevice: deviceId,
                        ),
                        thisDevice: deviceId,
                      ),
                    ],
                    if ((roles, profiles) case (
                      final roles?,
                      final profiles?,
                    )) ...[
                      const SizedBox(height: 8),
                      LinkedAccountsButton(
                        auth: auth,
                        roles: roles,
                        profiles: profiles,
                        sync: sync,
                      ),
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
          ),
        );
      },
    );
  }
}

/// Every device ID in [events] of [profileId] (the profile's devices, synced
/// from its cloud folder), sorted, with [thisDevice] first even before it
/// has an event.
List<String> profileDevices(
  Iterable<AppEvent> events, {
  required String profileId,
  String? thisDevice,
}) {
  final others = {
    for (final event in events)
      if (event.profileId == profileId) ?event.deviceId,
  }..remove(thisDevice);
  return [?thisDevice, ...others.toList()..sort()];
}

/// The profile's ID and its devices' IDs, each selectable to copy.
class ProfileDevices extends StatelessWidget {
  const ProfileDevices({
    super.key,
    required this.profile,
    required this.devices,
    this.thisDevice,
  });

  final String profile;
  final List<String> devices;

  /// Labelled "this device" in the list.
  final String? thisDevice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      key: const Key('profile-devices'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text('Profile', style: muted),
        SelectableText(
          profile,
          key: const Key('profile-id'),
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text(
          devices.length == 1 ? '1 device' : '${devices.length} devices',
          style: muted,
        ),
        for (final device in devices)
          Row(
            key: Key('profile-device-$device'),
            spacing: 8,
            children: [
              Icon(
                device == thisDevice ? Icons.smartphone : Icons.devices_other,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              Flexible(child: SelectableText(device)),
              if (device == thisDevice) Text('this device', style: muted),
            ],
          ),
      ],
    );
  }
}

/// Opens [LinkedAccountsSheet].
class LinkedAccountsButton extends StatelessWidget {
  const LinkedAccountsButton({
    super.key,
    required this.auth,
    required this.roles,
    required this.profiles,
    this.sync,
    this.label = 'Linked accounts',
  });

  final AuthService auth;
  final RolesService roles;
  final ProfileClient profiles;
  final CloudSync? sync;
  final String label;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const Key('linked-accounts'),
    icon: const Icon(Icons.link),
    label: Text(label),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Room for the keyboard under the code field.
      isScrollControlled: true,
      builder: (_) => LinkedAccountsSheet(
        auth: auth,
        roles: roles,
        profiles: profiles,
        sync: sync,
      ),
    ),
  );
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

/// One line about cloud uploads: syncing, synced (and how many), or why not
/// (with a Retry button once syncing has stopped).
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
            switch ((sync.uploaded, sync.downloaded)) {
              (0, 0) => 'Clips and events are backed up',
              (final up, 0) => 'Backed up ($up uploaded)',
              (0, final down) => 'Backed up ($down restored)',
              (final up, final down) =>
                'Backed up ($up uploaded, $down restored)',
            },
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
            if (sync.stopped)
              TextButton(
                key: const Key('cloud-sync-retry'),
                onPressed: sync.retry,
                child: const Text('Retry'),
              ),
          ],
        );
      },
    );
  }
}

/// Signed in without access: the sign-up icon. Its sheet lets the user ask
/// for membership with a message, redeem a voucher code, and check again.
class SignUpButton extends StatelessWidget {
  const SignUpButton({
    super.key,
    required this.auth,
    required this.roles,
    required this.membership,
    this.profiles,
  });

  final AuthService auth;
  final RolesService roles;
  final MembershipClient membership;
  final ProfileClient? profiles;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('sign-up'),
    tooltip: 'Sign up',
    icon: const Icon(Icons.person_add_alt_1),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Room for the keyboard under the message field.
      isScrollControlled: true,
      builder: (_) => SignUpSheet(
        auth: auth,
        roles: roles,
        membership: membership,
        profiles: profiles,
      ),
    ),
  );
}

class SignUpSheet extends StatefulWidget {
  const SignUpSheet({
    super.key,
    required this.auth,
    required this.roles,
    required this.membership,
    this.profiles,
  });

  final AuthService auth;
  final RolesService roles;
  final MembershipClient membership;

  /// When given, a member's other account can link to it instead.
  final ProfileClient? profiles;

  /// The auth API's limit.
  static const int maxMessage = 1000;

  @override
  State<SignUpSheet> createState() => _SignUpSheetState();
}

class _SignUpSheetState extends State<SignUpSheet> {
  final _message = TextEditingController();
  final _code = TextEditingController();
  bool _sending = false;
  bool _sent = false;
  String? _error;
  bool _redeeming = false;
  String? _codeError;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _message.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Redeems the voucher code, then re-asks the roles: a valid code lets the
  /// user in at once.
  Future<void> _redeem() async {
    final token = widget.auth.idToken;
    final code = _code.text.trim();
    if (token == null || code.isEmpty) return;
    setState(() {
      _redeeming = true;
      _codeError = null;
    });
    try {
      await widget.membership.redeem(token, code);
      if (mounted) _code.clear();
      await widget.roles.refresh();
    } on RolesException catch (e) {
      if (mounted) {
        setState(
          () => _codeError = switch (e.statusCode) {
            402 when e is PaymentRequiredException =>
              'That code gives ${e.discount}% off. Paying the rest isn\'t '
                  'available yet, so it can\'t let you in.',
            404 => 'That code is invalid, expired or used up.',
            429 => 'Too many tries right now. Try again in a minute.',
            _ => 'Couldn\'t redeem the code ($e).',
          },
        );
      }
    } catch (e) {
      if (mounted) setState(() => _codeError = 'Couldn\'t redeem the code.');
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  Future<void> _send() async {
    final token = widget.auth.idToken;
    final message = _message.text.trim();
    if (token == null || message.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.membership.request(token, message);
      if (mounted) setState(() => _sent = true);
    } on RolesException catch (e) {
      if (mounted) {
        setState(
          () => _error = switch (e.statusCode) {
            409 => 'You already sent a request. Try again in an hour.',
            429 => 'Too many requests right now. Try again in a minute.',
            _ => 'Couldn\'t send the request ($e).',
          },
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn\'t send the request.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final email = widget.auth.user?.email ?? 'Your account';
    return ListenableBuilder(
      listenable: widget.roles,
      builder: (context, _) => SafeArea(
        child: Padding(
          key: const Key('sign-up-sheet'),
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Icon(Icons.person_add_alt_1, size: 40, color: scheme.primary),
              Text('Request access', style: theme.textTheme.titleLarge),
              if (_sent)
                Text(
                  'Request sent. An administrator will review it; check '
                  'again once they have.',
                  key: const Key('membership-sent'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                )
              else ...[
                Text(
                  '$email doesn\'t have access to Presence yet. Tell the '
                  'administrators who you are and why you need it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                TextField(
                  key: const Key('membership-message'),
                  controller: _message,
                  enabled: !_sending,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: SignUpSheet.maxMessage,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_error case final error?)
                  Text(
                    error,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.error),
                  ),
                _sending
                    ? const CircularProgressIndicator()
                    : FilledButton.icon(
                        key: const Key('send-membership'),
                        icon: const Icon(Icons.send),
                        label: const Text('Send request'),
                        onPressed: _message.text.trim().isEmpty ? null : _send,
                      ),
              ],
              const Divider(),
              Text(
                'Have a voucher code? Redeem it to get in right away.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('voucher-code'),
                      controller: _code,
                      enabled: !_redeeming,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 20,
                      decoration: const InputDecoration(
                        labelText: 'Voucher code',
                        hintText: 'XXXX-XXXX-XXXX',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onSubmitted: (_) => _redeem(),
                    ),
                  ),
                  _redeeming
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          key: const Key('redeem-voucher'),
                          onPressed: _code.text.trim().isEmpty ? null : _redeem,
                          child: const Text('Redeem'),
                        ),
                ],
              ),
              if (_codeError case final error?)
                Text(
                  error,
                  key: const Key('voucher-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
              if (widget.profiles case final profiles?)
                LinkedAccountsButton(
                  auth: widget.auth,
                  roles: widget.roles,
                  profiles: profiles,
                  label: 'Have access with another Google account? Link it',
                ),
              widget.roles.state == AccessState.checking
                  ? const CircularProgressIndicator()
                  : TextButton.icon(
                      key: const Key('check-access'),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check again'),
                      onPressed: widget.roles.refresh,
                    ),
            ],
          ),
        ),
      ),
    );
  }
}
