import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_service.dart';
import 'membership_client.dart';
import 'roles_service.dart';
import 'voucher_code.dart';

/// Admins only (`presence_user` + `presence_admin`): the pending membership
/// requests, each with **Grant access** (gives it the `presence_user` role)
/// and **Dismiss**; then the voucher codes, which grant a role to whoever
/// redeems them, with a form to create one.
class AdminScreen extends StatefulWidget {
  const AdminScreen({
    super.key,
    required this.auth,
    required this.membership,
    this.canCreateAdmins = false,
  });

  final AuthService auth;
  final MembershipClient membership;

  /// Whether the user is a `presence_root`, who may also create Admin
  /// vouchers; admins create Member ones only.
  final bool canCreateAdmins;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  List<MembershipRequest>? _requests;
  String? _error;
  List<Voucher>? _vouchers;
  String? _vouchersError;

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

  /// Creates a voucher; true if it was.
  Future<bool> _create(
    String role,
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
    final now = DateTime.now();
    return Scaffold(
      key: const Key('admin-screen'),
      appBar: AppBar(
        title: const Text('Admin'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
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
                  (final list?, _) when list.isEmpty => [
                    status('No vouchers.'),
                  ],
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

/// A new voucher: its code (a suggestion of the season, an animal and a
/// number, or the admin's own; blank for a random one), role, expiry date
/// (the end of that day, local time), how many people may redeem it and
/// its discount.
class _VoucherForm extends StatefulWidget {
  const _VoucherForm({required this.onCreate, required this.roles});

  final Future<bool> Function(
    String role,
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
  late DateTime _expires = _today().add(const Duration(days: 7));
  final _uses = TextEditingController(text: '1');
  final _code = TextEditingController(text: suggestVoucherCode());
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

  /// Blank (a random code) or one the auth API takes.
  bool get _codeOk =>
      _code.text.trim().isEmpty || isValidVoucherCode(_code.text);

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

  Future<void> _pickDate() async {
    final today = _today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expires,
      firstDate: today,
      lastDate: today.add(const Duration(days: _VoucherForm.maxDays - 1)),
      helpText: 'Valid through',
    );
    if (picked != null && mounted) setState(() => _expires = picked);
  }

  Future<void> _create() async {
    final uses = _maxUses;
    final discount = _discountValue;
    if (uses == null || discount == null || !_codeOk) return;
    setState(() => _creating = true);
    // Valid through the whole chosen day.
    final end = DateTime(_expires.year, _expires.month, _expires.day + 1);
    final created = await widget.onCreate(
      _role,
      end,
      uses,
      _code.text.trim(),
      discount,
    );
    if (!mounted) return;
    setState(() => _creating = false);
    if (created) {
      _uses.text = '1';
      _discount.text = '100';
      _code.text = suggestVoucherCode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = MaterialLocalizations.of(context).formatShortDate(_expires);
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
                enabled: !_creating,
                textCapitalization: TextCapitalization.characters,
                maxLength: maxVoucherCode,
                decoration: InputDecoration(
                  labelText: 'Code',
                  border: const OutlineInputBorder(),
                  counterText: '',
                  helperText: 'Blank for a random code',
                  errorText: _codeOk
                      ? null
                      : '$minVoucherCode to $maxVoucherCode letters, digits '
                            'and dashes',
                  suffixIcon: IconButton(
                    key: const Key('suggest-code'),
                    tooltip: 'Suggest another',
                    icon: const Icon(Icons.casino_outlined),
                    onPressed: _creating
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
                    : (role) => setState(() => _role = role ?? userRole),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('voucher-expires'),
              icon: const Icon(Icons.event),
              label: Text('Valid through $date'),
              onPressed: _creating ? null : _pickDate,
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
    final expires = voucher.expiresAt.toLocal();
    final state = voucher.isExpired(now)
        ? 'Expired'
        : voucher.isUsedUp
        ? 'Used up'
        : null;
    return Card(
      key: Key('voucher-${voucher.code}'),
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
                    'expires ${localizations.formatShortDate(expires)} '
                    '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(expires))}',
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
        ),
      ),
    );
  }
}
