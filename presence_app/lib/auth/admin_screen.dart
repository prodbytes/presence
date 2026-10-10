import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../feedback/feedback_client.dart';
import '../feedback/feedback_inbox.dart';
import 'auth_service.dart';
import 'membership_client.dart';
import 'roles_service.dart';

/// The Admin tab's page, for admins only (`presence_user` +
/// `presence_admin`): maintenance mode's switch, with the sorry screen's
/// message; the pending membership requests, each with **Grant
/// access** (gives it the `presence_user` role) and **Dismiss**; the
/// members' Feedback and Help conversations, each with a Reply field; then
/// the voucher codes, which grant a role to whoever redeems them (created
/// in rbacr; here they're listed and deleted). A page of the home screen's tabs, like Settings: no
/// scaffold or app bar of its own; Reload sits by the first heading, and
/// pulling down reloads too.
class AdminView extends StatefulWidget {
  const AdminView({
    super.key,
    required this.auth,
    required this.membership,
    required this.feedback,
    this.onMaintenanceSwitched,
  });

  final AuthService auth;
  final MembershipClient membership;
  final FeedbackClient feedback;

  /// After maintenance mode is switched: the app asks the auth API again,
  /// so it follows at once.
  final Future<void> Function()? onMaintenanceSwitched;

  @override
  State<AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<AdminView> {
  List<MembershipRequest>? _requests;
  String? _error;
  List<Voucher>? _vouchers;
  String? _vouchersError;
  List<FeedbackThread>? _threads;
  String? _threadsError;
  MaintenanceSwitch? _maintenance;
  String? _maintenanceError;
  bool _switching = false;

  /// Emails with a grant or dismissal in flight, and voucher codes being
  /// deleted.
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = widget.auth.idToken;
    if (token == null) {
      setState(() => _error = 'Not signed in.');
      return;
    }
    setState(() {
      _error = null;
      _vouchersError = null;
      _threadsError = null;
      _maintenanceError = null;
    });
    await Future.wait([
      () async {
        try {
          final state = await widget.membership.maintenance(token);
          if (mounted) setState(() => _maintenance = state);
        } catch (e) {
          if (mounted) {
            setState(
              () => _maintenanceError = 'Couldn\'t load maintenance mode ($e).',
            );
          }
        }
      }(),
      () async {
        try {
          final requests = await widget.membership.list(token);
          if (mounted) setState(() => _requests = requests);
        } catch (e) {
          if (mounted) setState(() => _error = 'Couldn\'t load requests ($e).');
        }
      }(),
      () async {
        try {
          final threads = await widget.feedback.threads(token);
          if (mounted) setState(() => _threads = threads);
        } catch (e) {
          if (mounted) {
            setState(() => _threadsError = 'Couldn\'t load feedback ($e).');
          }
        }
      }(),
      () async {
        try {
          final vouchers = await widget.membership.vouchers(token);
          if (mounted) setState(() => _vouchers = vouchers);
        } catch (e) {
          if (mounted) {
            setState(() => _vouchersError = 'Couldn\'t load vouchers ($e).');
          }
        }
      }(),
    ]);
  }

  Future<void> _act(MembershipRequest request, {required bool grant}) async {
    final token = widget.auth.idToken;
    if (token == null) return;
    setState(() => _busy.add(request.email));
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (grant) {
        await widget.membership.grant(token, request.email);
      } else {
        await widget.membership.dismiss(token, request.email);
      }
      if (!mounted) return;
      setState(() => _requests?.remove(request));
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            grant
                ? '${request.email} can now use Presence'
                : 'Dismissed ${request.email}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t update ${request.email} ($e)')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(request.email));
    }
  }

  /// Answers [thread] with [text]; true if it was sent.
  Future<bool> _reply(FeedbackThread thread, String text) async {
    final token = widget.auth.idToken;
    if (token == null) return false;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final reply = await widget.feedback.reply(token, thread.email, text);
      if (!mounted) return true;
      setState(() {
        final threads = _threads;
        if (threads == null) return;
        // Answered last: first in the list.
        _threads = [
          FeedbackThread(
            email: thread.email,
            name: thread.name,
            messages: [...thread.messages, reply],
          ),
          ...threads.where((t) => t.email != thread.email),
        ];
      });
      return true;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t reply to ${thread.email} ($e)')),
      );
      return false;
    }
  }

  /// Switches maintenance mode; true if it was.
  Future<bool> _switchMaintenance(bool on, String message) async {
    final token = widget.auth.idToken;
    if (token == null) return false;
    setState(() => _switching = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final state = await widget.membership.setMaintenance(
        token,
        on: on,
        message: message,
      );
      if (mounted) setState(() => _maintenance = state);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            on
                ? 'Maintenance mode is on: everyone else sees the sorry message'
                : 'Maintenance mode is off',
          ),
        ),
      );
      await widget.onMaintenanceSwitched?.call();
      return true;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t switch maintenance mode ($e)')),
      );
      return false;
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _delete(Voucher voucher) async {
    final token = widget.auth.idToken;
    if (token == null) return;
    setState(() => _busy.add(voucher.code));
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.membership.deleteVoucher(token, voucher.code);
      if (!mounted) return;
      setState(() => _vouchers?.remove(voucher));
      messenger.showSnackBar(
        SnackBar(content: Text('Deleted voucher ${voucher.code}')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Couldn\'t delete ${voucher.code} ($e)')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(voucher.code));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget status(String text, {bool error = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: error ? scheme.error : scheme.onSurfaceVariant),
      ),
    );
    const loading = Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: CircularProgressIndicator()),
    );
    final requests = _requests;
    final vouchers = _vouchers;
    final threads = _threads;
    final now = DateTime.now();
    return Center(
      key: const Key('admin-view'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Maintenance mode',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const Key('admin-reload'),
                    tooltip: 'Reload',
                    icon: const Icon(Icons.refresh),
                    onPressed: _load,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              switch ((_maintenance, _maintenanceError)) {
                (_, final error?) => status(error, error: true),
                (null, _) => loading,
                (final state?, _) => _MaintenanceCard(
                  // A fresh message field for each state loaded.
                  key: ValueKey(state),
                  state: state,
                  busy: _switching,
                  onSwitch: _switchMaintenance,
                ),
              },
              const SizedBox(height: 24),
              Text('Membership requests', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              ...switch ((requests, _error)) {
                (_, final error?) => [status(error, error: true)],
                (null, _) => [loading],
                (final list?, _) when list.isEmpty => [
                  status('No pending requests.'),
                ],
                (final list?, _) => [
                  for (final request in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _RequestCard(
                        request: request,
                        busy: _busy.contains(request.email),
                        onGrant: () => _act(request, grant: true),
                        onDismiss: () => _act(request, grant: false),
                      ),
                    ),
                ],
              },
              const SizedBox(height: 24),
              Text('Feedback', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Members\' messages from the Help tab, the latest active '
                'first. Your replies show there.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              ...switch ((threads, _threadsError)) {
                (_, final error?) => [status(error, error: true)],
                (null, _) => [loading],
                (final list?, _) when list.isEmpty => [
                  status('No feedback yet.'),
                ],
                (final list?, _) => [
                  for (final thread in list)
                    Padding(
                      // Moves with its thread (a reply puts it first),
                      // staying open.
                      key: ValueKey('thread-${thread.email}'),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FeedbackThreadCard(
                        thread: thread,
                        onReply: (text) => _reply(thread, text),
                      ),
                    ),
                ],
              },
              const SizedBox(height: 24),
              Text('Voucher codes', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Whoever redeems a code on the Request access sheet gets '
                'its role at once. Codes are created in rbacr.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              ...switch ((vouchers, _vouchersError)) {
                (_, final error?) => [status(error, error: true)],
                (null, _) => [loading],
                (final list?, _) when list.isEmpty => [status('No vouchers.')],
                (final list?, _) => [
                  for (final voucher in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _VoucherCard(
                        voucher: voucher,
                        now: now,
                        busy: _busy.contains(voucher.code),
                        onDelete: () => _delete(voucher),
                      ),
                    ),
                ],
              },
            ],
          ),
        ),
      ),
    );
  }
}

/// Maintenance mode's switch: while it's on, everyone but admins sees only
/// a sorry message, with the [message] typed here.
class _MaintenanceCard extends StatefulWidget {
  const _MaintenanceCard({
    super.key,
    required this.state,
    required this.busy,
    required this.onSwitch,
  });

  final MaintenanceSwitch state;
  final bool busy;
  final Future<bool> Function(bool on, String message) onSwitch;

  @override
  State<_MaintenanceCard> createState() => _MaintenanceCardState();
}

class _MaintenanceCardState extends State<_MaintenanceCard> {
  late final _message = TextEditingController(text: widget.state.state.message);

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (:state, :by) = widget.state;
    final since = state.since?.toLocal();
    final when = since == null
        ? null
        : '${since.year}-${_two(since.month)}-${_two(since.day)} '
              '${_two(since.hour)}:${_two(since.minute)}';
    return Card(
      key: const Key('maintenance-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const Key('maintenance-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(state.on ? 'On' : 'Off'),
              subtitle: Text(
                [
                  state.on
                      ? 'Everyone but admins sees only the sorry message.'
                      : 'Turn on to show everyone but admins only a sorry '
                            'message.',
                  if (when != null)
                    '${state.on ? 'On' : 'Off'} since $when'
                        '${by.isEmpty ? '' : ' ($by)'}.',
                ].join(' '),
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              value: state.on,
              onChanged: widget.busy
                  ? null
                  : (on) => widget.onSwitch(on, on ? _message.text : ''),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('maintenance-message-field'),
              controller: _message,
              enabled: !widget.busy,
              maxLength: 500,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Message (optional)',
                hintText: 'We expect to be back by noon.',
                helperText: 'Shown under the sorry message.',
              ),
            ),
            if (state.on)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('maintenance-update-message'),
                  onPressed: widget.busy
                      ? null
                      : () => widget.onSwitch(true, _message.text),
                  child: const Text('Update message'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.request,
    required this.busy,
    required this.onGrant,
    required this.onDismiss,
  });

  final MembershipRequest request;
  final bool busy;
  final VoidCallback onGrant;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final when = MaterialLocalizations.of(context)
        .formatShortDate(request.requestedAt.toLocal());
    return Card(
      key: Key('request-${request.email}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              request.name.isEmpty ? request.email : request.name,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              request.name.isEmpty ? when : '${request.email} · $when',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            SelectableText(request.message),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 8,
              children: busy
                  ? const [
                      SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ]
                  : [
                      TextButton(
                        key: Key('dismiss-${request.email}'),
                        onPressed: onDismiss,
                        child: const Text('Dismiss'),
                      ),
                      FilledButton(
                        key: Key('grant-${request.email}'),
                        onPressed: onGrant,
                        child: const Text('Grant access'),
                      ),
                    ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The role a voucher grants, as the Admin screen names it.
String _roleLabel(String role) => switch (role) {
  userRole => 'Member',
  adminRole => 'Admin',
  _ => role,
};

class _VoucherCard extends StatelessWidget {
  const _VoucherCard({
    required this.voucher,
    required this.now,
    required this.busy,
    required this.onDelete,
  });

  final Voucher voucher;
  final DateTime now;
  final bool busy;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final starts = voucher.startsAt.toLocal();
    final expires = voucher.expiresAt.toLocal();
    String at(DateTime t) =>
        '${localizations.formatShortDate(t)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(t))}';
    final state = voucher.isExpired(now)
        ? 'Expired'
        : voucher.isUsedUp
        ? 'Used up'
        : voucher.isNotYetValid(now)
        ? 'Not yet valid'
        : null;
    // A hidden (Admin) code: only roots see it; keyed by its creation.
    final id = voucher.hidden
        ? 'hidden-${voucher.createdAt.millisecondsSinceEpoch}'
        : voucher.code;
    return Card(
      key: Key('voucher-$id'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          spacing: 8,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    spacing: 8,
                    children: [
                      if (voucher.hidden)
                        Text(
                          'Hidden code',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      else
                        SelectableText(
                          voucher.code,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontFamily: 'monospace',
                            decoration: state == null
                                ? null
                                : TextDecoration.lineThrough,
                          ),
                        ),
                      if (state != null)
                        Text(state, style: TextStyle(color: scheme.error)),
                    ],
                  ),
                  Text(
                    '${_roleLabel(voucher.role)} · '
                    '${voucher.discount}% off · '
                    '${voucher.uses} of ${voucher.maxUses} used · '
                    'valid from ${at(starts)} · '
                    'expires ${at(expires)}',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  if (voucher.redeemedBy.isNotEmpty)
                    Text(
                      'Redeemed by ${voucher.redeemedBy.join(', ')}',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                ],
              ),
            ),
            // A hidden code can't be copied or deleted (only by a root).
            if (!voucher.hidden) ...[
              IconButton(
                key: Key('copy-${voucher.code}'),
                tooltip: 'Copy code',
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: voucher.code));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Copied ${voucher.code}')),
                  );
                },
              ),
              busy
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      key: Key('delete-${voucher.code}'),
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: onDelete,
                    ),
            ],
          ],
        ),
      ),
    );
  }
}
