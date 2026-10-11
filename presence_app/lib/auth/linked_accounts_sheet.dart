import 'package:flutter/material.dart';

import '../cloud/cloud_sync.dart';
import '../l10n/l10n.dart';
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

  /// The last failure and the last success, in the language shown.
  String Function(AppLocalizations l10n)? _error;
  String Function(AppLocalizations l10n)? _done;

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
      if (mounted) setState(() => _error = (l) => _describe(l, e.statusCode));
    } catch (e) {
      if (mounted) setState(() => _error = (l) => l.authSomethingWrong('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _describe(AppLocalizations l, int status) => switch (status) {
    404 => l.authLinkCodeWrong,
    409 => l.authLinkConflict,
    429 => l.authLinkTooMany,
    503 => l.authLinkNoBackup,
    _ => l.authRequestFailed(status),
  };

  /// The account joined or left a profile: new roles, and a new folder.
  void _changed(
    List<ProfileAccount> accounts,
    String Function(AppLocalizations l10n) message,
  ) {
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
      (l) =>
          owner.isEmpty ? l.authLinkedToProfile : l.authLinkedTo(owner.first),
    );
  });

  void _unlink(ProfileAccount account) => _run((token) async {
    final accounts = await widget.profiles.unlink(token, account.email);
    if (!mounted) return;
    _changed(accounts, (l) => l.authUnlinked(account.email));
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
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
              Text(l10n.authLinkedAccounts, style: theme.textTheme.titleLarge),
              Text(
                l10n.authLinkedIntro,
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
                      if (account.owner) l10n.authOwner,
                      if (account.current) l10n.authThisAccount,
                    ].join(' · '),
                  ),
                  trailing: account.owner
                      ? null
                      : IconButton(
                          key: Key('unlink-${account.email}'),
                          tooltip: l10n.authUnlink,
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
                    label: Text(l10n.authLinkAnother),
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
                    l10n.authLinkCodeHelp,
                    textAlign: TextAlign.center,
                    style: muted,
                  ),
                ],
              ],
              const Divider(),
              Text(
                l10n.authHaveCode,
                textAlign: TextAlign.center,
                style: muted,
              ),
              TextField(
                key: const Key('link-code-field'),
                controller: _code,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: l10n.authLinkCode,
                  hintText: 'ABCD-EFGH',
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _code.text.trim().isEmpty ? null : _link(),
              ),
              OutlinedButton.icon(
                key: const Key('use-link-code'),
                icon: const Icon(Icons.link),
                label: Text(l10n.authLinkThis),
                onPressed: _busy || _code.text.trim().isEmpty ? null : _link,
              ),
              if (_done case final done?)
                Text(
                  done(l10n),
                  key: const Key('linked-done'),
                  textAlign: TextAlign.center,
                ),
              if (_error case final error?)
                Text(
                  error(l10n),
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
