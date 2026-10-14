import 'package:flutter/material.dart';

import '../about.dart';
import '../l10n/l10n.dart';
import 'api_config.dart';
import 'auth_service.dart';
import 'profile_client.dart';
import 'roles_service.dart';
import 'store_billing.dart';

/// Deletes the signed-in account at the auth API, then forgets its
/// profile on this device and signs out (`_deleteAccount` in main.dart).
/// Answers what the API deleted; one not [AccountDeletion.complete] (the
/// cloud folder is still being deleted) left this device as it was.
typedef DeleteAccount = Future<AccountDeletion> Function();

/// The site's page on deleting an account, whose "Subscriptions" part
/// says how to cancel Premium bought on the web (Stripe), which deleting
/// doesn't; on iOS and Android the dialog links to the store instead.
Uri get deleteAccountPage =>
    ApiConfig.baseUrl.resolve('/delete-account#subscriptions');

/// The account sheet's last action: **Delete account** (error-colored),
/// which asks first ([DeleteAccountDialog]) and, once deleted, closes the
/// sheet and says so in a snack bar.
class DeleteAccountButton extends StatelessWidget {
  const DeleteAccountButton({
    super.key,
    required this.auth,
    required this.profiles,
    required this.profile,
    required this.delete,
    this.openLink,
  });

  final AuthService auth;
  final ProfileClient profiles;

  /// The profile shown, which the API checks is still the account's.
  final String profile;
  final DeleteAccount delete;

  /// Opens the subscriptions link (tests); defaults to the browser.
  final LinkOpener? openLink;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextButton.icon(
      key: const Key('delete-account'),
      style: TextButton.styleFrom(foregroundColor: scheme.error),
      icon: const Icon(Icons.person_remove_outlined),
      label: Text(context.l10n.authDeleteAccount),
      onPressed: () => deleteAccountAfterConfirming(
        context,
        auth: auth,
        profiles: profiles,
        profile: profile,
        delete: delete,
        openLink: openLink,
      ),
    );
  }
}

/// Asks with [DeleteAccountDialog], which deletes the account with
/// [delete]; once it's deleted, closes the account sheet (a bottom sheet;
/// nothing as the Profile tab's page) and says what went.
Future<void> deleteAccountAfterConfirming(
  BuildContext context, {
  required AuthService auth,
  required ProfileClient profiles,
  required String profile,
  required DeleteAccount delete,
  LinkOpener? openLink,
}) async {
  // Found now: the sheet asking is gone once the account is.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  final l = context.l10n;
  final result = await showDialog<AccountDeletion>(
    context: context,
    builder: (_) => DeleteAccountDialog(
      auth: auth,
      profiles: profiles,
      profile: profile,
      delete: delete,
      openLink: openLink,
    ),
  );
  if (result == null) return;
  navigator.maybePop();
  messenger?.showSnackBar(
    SnackBar(
      key: const Key('account-deleted'),
      content: Text(
        result.wholeProfile
            ? l.authDeleteAccountDone
            : l.authDeleteAccountUnlinked,
      ),
    ),
  );
}

/// "Delete your account?": what goes (the owner: the whole profile, its
/// cloud data and every linked account's access; a linked account: only
/// its link, the profile staying its owner's), that this device forgets
/// the profile and signs out, that a Premium subscription isn't cancelled
/// (with a link to how to cancel it), and a checkbox to confirm before
/// **Delete account** works. Deletes with [delete] itself, showing why it
/// failed (it can be tried again); pops the [AccountDeletion] once done,
/// or null when cancelled.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({
    super.key,
    required this.auth,
    required this.profiles,
    required this.profile,
    required this.delete,
    this.openLink,
  });

  final AuthService auth;
  final ProfileClient profiles;
  final String profile;
  final DeleteAccount delete;
  final LinkOpener? openLink;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  /// The profile's accounts, to tell the owner from a linked account;
  /// null while they load, or if they couldn't (then it says both cases).
  List<ProfileAccount>? _accounts;
  bool _loading = true;
  bool _confirmed = false;
  bool _deleting = false;
  String Function(AppLocalizations l)? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.auth.idToken;
    try {
      if (token != null) {
        final accounts = await widget.profiles.accounts(token);
        if (mounted) setState(() => _accounts = accounts);
      }
    } catch (e) {
      debugPrint('Presence: could not list the profile\'s accounts: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete() async {
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      final result = await widget.delete();
      if (!mounted) return;
      if (!result.complete) {
        setState(() => _error = (l) => l.authDeleteAccountUnfinished);
        return;
      }
      Navigator.of(context).pop(result);
    } on RolesException catch (e) {
      debugPrint('Presence: could not delete the account: $e');
      if (mounted) {
        setState(
          () => _error = switch (e.statusCode) {
            401 || 403 => (l) => l.authDeleteAccountSignInAgain,
            409 => (l) => l.authDeleteAccountChanged,
            429 => (l) => l.authLinkTooMany,
            _ => (l) => l.authDeleteAccountFailed('HTTP ${e.statusCode}'),
          },
        );
      }
    } catch (e) {
      debugPrint('Presence: could not delete the account: $e');
      if (mounted) {
        setState(() => _error = (l) => l.authDeleteAccountFailed('$e'));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accounts = _accounts;
    final me = accounts?.where((a) => a.current).firstOrNull;
    final owner = accounts?.where((a) => a.owner).firstOrNull;
    final others = [
      for (final a in accounts ?? const <ProfileAccount>[])
        if (!a.current) a.email,
    ];
    // Unknown (the list didn't load): the owner's case, which says most.
    final isOwner = me == null || me.owner;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return AlertDialog(
      key: const Key('delete-account-dialog'),
      icon: Icon(Icons.person_remove_outlined, color: scheme.error),
      title: Text(l.authDeleteAccountTitle),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (isOwner) ...[
            Text(
              l.authDeleteAccountOwner(widget.profile),
              key: const Key('delete-account-owner'),
            ),
            if (others.isNotEmpty)
              Text(
                l.authDeleteAccountOthers(others.join(', ')),
                key: const Key('delete-account-others'),
              ),
          ] else
            Text(
              l.authDeleteAccountLinked(
                me.email,
                widget.profile,
                owner?.email ?? '',
              ),
              key: const Key('delete-account-linked'),
            ),
          Text(l.authDeleteAccountDevice, style: muted),
          // On iOS and Android Premium is the store's: its own settings,
          // never Stripe (App Store 3.1.1).
          if (PurchaseChannel.current case final channel when channel.isStore)
            Text(
              l.storeDeleteAccountSubscription(channel.storeName),
              style: muted,
            )
          else
            Text(l.authDeleteAccountSubscription, style: muted),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('delete-account-subscriptions'),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(
                PurchaseChannel.current.isStore
                    ? l.storeManage
                    : l.authDeleteAccountManage,
              ),
              onPressed: () => openOrCopyLink(
                context,
                PurchaseChannel.current.isStore
                    ? StoreProducts.manage(PurchaseChannel.current)
                    : deleteAccountPage,
                widget.openLink ?? launchLink,
              ),
            ),
          ),
          CheckboxListTile(
            key: const Key('delete-account-confirm'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _confirmed,
            onChanged: _deleting || _loading
                ? null
                : (v) => setState(() => _confirmed = v ?? false),
            title: Text(l.authDeleteAccountConfirm),
          ),
          if (_error case final error?)
            Text(
              error(l),
              key: const Key('delete-account-error'),
              style: TextStyle(color: scheme.error),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('delete-account-cancel'),
          onPressed: _deleting ? null : () => Navigator.of(context).pop(),
          child: Text(l.authDeleteAccountCancel),
        ),
        FilledButton(
          key: const Key('delete-account-go'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _confirmed && !_deleting && !_loading ? _delete : null,
          child: _deleting
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onError,
                  ),
                )
              : Text(l.authDeleteAccount),
        ),
      ],
    );
  }
}
