import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../feedback/feedback_client.dart';
import '../feedback/feedback_inbox.dart';
import 'auth_service.dart';
import 'membership_client.dart';
import 'roles_service.dart';
import 'voucher_code.dart';

/// The Admin tab's page, for admins only (`presence_user` +
/// `presence_admin`): the pending membership requests, each with **Grant
/// access** (gives it the `presence_user` role) and **Dismiss**; the
/// members' Feedback and Help conversations, each with a Reply field; then
/// the voucher codes, which grant a role to whoever redeems them, with a form
/// to create one. A page of the home screen's tabs, like Settings: no
/// scaffold or app bar of its own; Reload sits by the first heading, and
/// pulling down reloads too.
class AdminView extends StatefulWidget {
  const AdminView({
    super.key,
    required this.auth,
    required this.membership,
    required this.feedback,
    this.canCreateAdmins = false,
  });

  final AuthService auth;
  final MembershipClient membership;
  final FeedbackClient feedback;

  /// Whether the user is a `presence_root`, who may also create Admin
  /// vouchers; admins create Member ones only.
  final bool canCreateAdmins;

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
    });
    await Future.wait([
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

  /// Creates a voucher; true if it was.
  Future<bool> _create(
    String role,
    DateTime startsAt,
    DateTime expiresAt,
    int maxUses,
    String code,
    int discount,
  ) async {
    final token = widget.auth.idToken;
    if (token == null) return false;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final voucher = await widget.membership.createVoucher(
        token,
        role: role,
        startsAt: startsAt,
        expiresAt: expiresAt,
        maxUses: maxUses,
        code: code,
        discount: discount,
      );
      if (!mounted) return true;
      setState(() => _vouchers = [voucher, ...?_vouchers]);
      messenger.showSnackBar(
        SnackBar(content: Text('Created voucher ${voucher.code}')),
      );
      return true;
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e is RolesException && e.statusCode == 409
                ? 'That code is taken; pick another.'
                : 'Couldn\'t create the voucher ($e)',
          ),
        ),
      );
      return false;
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
                      'Membership requests',
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
                widget.canCreateAdmins
                    ? 'Whoever redeems a code on the Request access sheet '
                          'gets its role at once. Admin codes also grant '
                          'Member.'
                    : 'Whoever redeems a code on the Request access sheet '
                          'becomes a Member at once. Only roots create '
                          'Admin codes.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              _VoucherForm(
                onCreate: _create,
                roles: widget.canCreateAdmins
                    ? const [userRole, adminRole]
                    : const [userRole],
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

/// A new voucher: its code (blank, the default, for the auth API's random
/// one; or, for Member codes only, the admin's own or a suggestion of the
/// season, an animal and a number, on request), role, first and
/// last valid days (from the start of the first, through the end of the
/// last, local time; the current season's by default), how many people may
/// redeem it and its discount.
class _VoucherForm extends StatefulWidget {
  const _VoucherForm({required this.onCreate, required this.roles});

  final Future<bool> Function(
    String role,
    DateTime startsAt,
    DateTime expiresAt,
    int maxUses,
    String code,
    int discount,
  )
  onCreate;

  /// The roles this user may create codes for.
  final List<String> roles;

  /// The auth API's limits.
  static const int maxUses = 1000;
  static const int maxDays = 365;

  @override
  State<_VoucherForm> createState() => _VoucherFormState();
}

class _VoucherFormState extends State<_VoucherForm> {
  String _role = userRole;
  // The current season, by default.
  late DateTime _starts = seasonStart(_today());
  late DateTime _expires = seasonEnd(_today());
  final _uses = TextEditingController(text: '1');
  // Blank: a random code, the hardest to guess.
  final _code = TextEditingController();
  final _discount = TextEditingController(text: '100');
  bool _creating = false;

  static DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  int? get _maxUses {
    final n = int.tryParse(_uses.text.trim());
    return n != null && n >= 1 && n <= _VoucherForm.maxUses ? n : null;
  }

  int? get _discountValue {
    final n = int.tryParse(_discount.text.trim());
    return n != null && n >= 1 && n <= 100 ? n : null;
  }

  /// Admin codes are always random: only Member codes may be chosen.
  bool get _canChoose => _role != adminRole;

  /// Blank (a random code) or, when it may be chosen, one the auth API takes.
  bool get _codeOk =>
      _code.text.trim().isEmpty ||
      (_canChoose && isValidVoucherCode(_code.text));

  bool get _valid => _maxUses != null && _discountValue != null && _codeOk;

  @override
  void initState() {
    super.initState();
    for (final c in [_uses, _code, _discount]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _uses.dispose();
    _code.dispose();
    _discount.dispose();
    super.dispose();
  }

  /// The last day a voucher made today may be valid through.
  DateTime _lastDay() =>
      _today().add(const Duration(days: _VoucherForm.maxDays - 1));

  Future<void> _pickStart() async {
    final today = _today();
    final last = _lastDay();
    // Back to the season's start, or a year, for codes valid already.
    final first = today.subtract(const Duration(days: _VoucherForm.maxDays));
    final picked = await showDatePicker(
      context: context,
      initialDate: _clamp(_starts, first, last),
      firstDate: first,
      lastDate: last,
      helpText: 'Valid from',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _starts = picked;
      // The last day can't come before the first.
      if (_expires.isBefore(picked)) _expires = picked;
    });
  }

  Future<void> _pickEnd() async {
    final today = _today();
    final first = _starts.isAfter(today) ? _starts : today;
    final last = _lastDay();
    final picked = await showDatePicker(
      context: context,
      initialDate: _clamp(_expires, first, last),
      firstDate: first,
      lastDate: last,
      helpText: 'Valid through',
    );
    if (picked != null && mounted) setState(() => _expires = picked);
  }

  static DateTime _clamp(DateTime date, DateTime first, DateTime last) =>
      date.isBefore(first) ? first : (date.isAfter(last) ? last : date);

  Future<void> _create() async {
    final uses = _maxUses;
    final discount = _discountValue;
    if (uses == null || discount == null || !_codeOk) return;
    setState(() => _creating = true);
    // Valid from the start of the first day through the whole last day.
    final start = DateTime(_starts.year, _starts.month, _starts.day);
    final end = DateTime(_expires.year, _expires.month, _expires.day + 1);
    final created = await widget.onCreate(
      _role,
      start,
      end,
      uses,
      _canChoose ? _code.text.trim() : '',
      discount,
    );
    if (!mounted) return;
    setState(() => _creating = false);
    if (created) {
      _uses.text = '1';
      _discount.text = '100';
      _code.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final from = localizations.formatShortDate(_starts);
    final through = localizations.formatShortDate(_expires);
    return Card(
      key: const Key('voucher-form'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 300,
              child: TextField(
                key: const Key('voucher-new-code'),
                controller: _code,
                enabled: !_creating && _canChoose,
                textCapitalization: TextCapitalization.characters,
                maxLength: maxVoucherCode,
                decoration: InputDecoration(
                  labelText: 'Code',
                  border: const OutlineInputBorder(),
                  counterText: '',
                  helperText: _canChoose
                      ? 'Blank for a random code (the safest)'
                      : 'Admin codes are always random',
                  errorText: _codeOk
                      ? null
                      : 'At least $minVoucherCode letters and digits, '
                            'up to $maxVoucherCode with dashes',
                  suffixIcon: IconButton(
                    key: const Key('suggest-code'),
                    tooltip: 'Suggest a code (easier to guess)',
                    icon: const Icon(Icons.casino_outlined),
                    onPressed: _creating || !_canChoose
                        ? null
                        : () => _code.text = suggestVoucherCode(),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 160,
              child: DropdownButtonFormField<String>(
                key: const Key('voucher-role'),
                initialValue: _role,
                decoration: const InputDecoration(
                  labelText: 'Grants',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final role in widget.roles)
                    DropdownMenuItem(
                      value: role,
                      child: Text(_roleLabel(role)),
                    ),
                ],
                onChanged: _creating
                    ? null
                    : (role) => setState(() {
                        _role = role ?? userRole;
                        // An Admin code is random: drop a chosen one.
                        if (!_canChoose) _code.clear();
                      }),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('voucher-starts'),
              icon: const Icon(Icons.event_available),
              label: Text('Valid from $from'),
              onPressed: _creating ? null : _pickStart,
            ),
            OutlinedButton.icon(
              key: const Key('voucher-expires'),
              icon: const Icon(Icons.event_busy),
              label: Text('Valid through $through'),
              onPressed: _creating ? null : _pickEnd,
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: const Key('voucher-max-uses'),
                controller: _uses,
                enabled: !_creating,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Uses',
                  border: const OutlineInputBorder(),
                  errorText: _maxUses == null
                      ? '1 to ${_VoucherForm.maxUses}'
                      : null,
                ),
              ),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: const Key('voucher-discount'),
                controller: _discount,
                enabled: !_creating,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Discount',
                  suffixText: '%',
                  border: const OutlineInputBorder(),
                  errorText: _discountValue == null ? '1 to 100' : null,
                ),
              ),
            ),
            _creating
                ? const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : FilledButton.icon(
                    key: const Key('create-voucher'),
                    icon: const Icon(Icons.add),
                    label: const Text('Create code'),
                    onPressed: _valid ? _create : null,
                  ),
          ],
        ),
      ),
    );
  }
}

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
