import 'package:flutter/material.dart';

import '../cloud/cloud_sync.dart';
import 'auth_service.dart';
import 'profile_client.dart';
import 'roles_service.dart';

/// The signed-in user's profile: the Google accounts that reach the same
/// clips and events. A member makes a one-time code here; the other account,
/// signed in, enters it to join. Accounts other than the owner can be
/// unlinked.
class LinkedAccountsSheet extends StatefulWidget {
  const LinkedAccountsSheet({
    super.key,
    required this.auth,
    required this.roles,
    required this.profiles,
    this.sync,
  });

  final AuthService auth;
  final RolesService roles;
  final ProfileClient profiles;

  /// Starts over after a link or unlink: the account's folder changes.
  final CloudSync? sync;

  @override
  State<LinkedAccountsSheet> createState() => _LinkedAccountsSheetState();
}

class _LinkedAccountsSheetState extends State<LinkedAccountsSheet> {
  final _code = TextEditingController();
  List<ProfileAccount>? _accounts;
  LinkCode? _linkCode;
  bool _busy = false;
  String? _error;
  String? _done;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
    _run((token) async {
      final accounts = await widget.profiles.accounts(token);
      if (mounted) setState(() => _accounts = accounts);
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// Runs [action] with the ID token, showing progress and any failure.
  Future<void> _run(Future<void> Function(String token) action) async {
    final token = widget.auth.idToken;
    if (token == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      await action(token);
    } on RolesException catch (e) {
      if (mounted) setState(() => _error = _describe(e.statusCode));
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong ($e).');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(int status) => switch (status) {
    404 => 'That code is wrong, already used or expired.',
    409 =>
      'This account can\'t be linked: it has cloud data of its own, or '
          'other accounts are linked to it.',
    429 => 'Too many tries. Wait a minute and try again.',
    503 => 'Cloud backup isn\'t set up, so accounts can\'t be linked.',
    _ => 'The request failed (HTTP $status).',
  };

  /// The account joined or left a profile: new roles, and a new folder.
  void _changed(List<ProfileAccount> accounts, String message) {
    setState(() {
      _accounts = accounts;
      _done = message;
      _code.clear();
    });
    widget.roles.refresh();
    widget.sync?.reconnect();
  }

  void _makeCode() => _run((token) async {
    final code = await widget.profiles.linkCode(token);
    if (mounted) setState(() => _linkCode = code);
  });

  void _link() => _run((token) async {
    final accounts = await widget.profiles.link(token, _code.text.trim());
    if (!mounted) return;
    final owner = accounts.where((a) => a.owner).map((a) => a.email);
    _changed(
      accounts,
      'Linked to ${owner.isEmpty ? 'the profile' : owner.first}.',
    );
  });

  void _unlink(ProfileAccount account) => _run((token) async {
    final accounts = await widget.profiles.unlink(token, account.email);
    if (!mounted) return;
    _changed(accounts, '${account.email} was unlinked.');
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final accounts = _accounts;
    final code = _linkCode;
    return ListenableBuilder(
      listenable: widget.roles,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          key: const Key('linked-accounts-sheet'),
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
              Text('Linked accounts', style: theme.textTheme.titleLarge),
              Text(
                'Any of these Google accounts reaches the same clips and '
                'events.',
                textAlign: TextAlign.center,
                style: muted,
              ),
              if (accounts == null && _busy) const CircularProgressIndicator(),
              for (final account in accounts ?? const <ProfileAccount>[])
                ListTile(
                  key: Key('linked-${account.email}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    account.owner ? Icons.star_outline : Icons.link,
                  ),
                  title: Text(account.email),
                  subtitle: Text(
                    [
                      if (account.owner) 'Owner',
                      if (account.current) 'This account',
                    ].join(' · '),
                  ),
                  trailing: account.owner
                      ? null
                      : IconButton(
                          key: Key('unlink-${account.email}'),
                          tooltip: 'Unlink',
                          icon: const Icon(Icons.link_off),
                          onPressed: _busy ? null : () => _unlink(account),
                        ),
                ),
              if (widget.roles.hasAccess) ...[
                const Divider(),
                if (code == null)
                  FilledButton.icon(
                    key: const Key('make-link-code'),
                    icon: const Icon(Icons.add_link),
                    label: const Text('Link another account'),
                    onPressed: _busy ? null : _makeCode,
                  )
                else ...[
                  SelectableText(
                    code.code,
                    key: const Key('link-code'),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      letterSpacing: 4,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  Text(
                    'Within 10 minutes, sign in with the other Google '
                    'account and enter this code under Linked accounts.',
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                ],
              ],
              const Divider(),
              Text(
                'Have a code from your other account? Enter it to link this '
                'one to it.',
                textAlign: TextAlign.center,
                style: muted,
              ),
              TextField(
                key: const Key('link-code-field'),
                controller: _code,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Link code',
                  hintText: 'ABCD-EFGH',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _code.text.trim().isEmpty ? null : _link(),
              ),
              OutlinedButton.icon(
                key: const Key('use-link-code'),
                icon: const Icon(Icons.link),
                label: const Text('Link this account'),
                onPressed: _busy || _code.text.trim().isEmpty ? null : _link,
              ),
              if (_done case final done?)
                Text(
                  done,
                  key: const Key('linked-done'),
                  textAlign: TextAlign.center,
                ),
              if (_error case final error?)
                Text(
                  error,
                  key: const Key('linked-error'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
