import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'payments_client.dart';
import 'premium_checkout.dart';

/// The Admin tab's Payments section: the Premium plans' Stripe Payment
/// Links, monthly and yearly, which free members upgrade with, and the Pro
/// plans', which members upgrade to Pro with (none until saved here). Saved
/// through the payments API (`PUT /api/payments/links`, admins only); a
/// field left empty is a plan that isn't offered.
class PaymentLinksEditor extends StatefulWidget {
  const PaymentLinksEditor({super.key, required this.payments});

  final PaymentsService payments;

  @override
  State<PaymentLinksEditor> createState() => _PaymentLinksEditorState();
}

class _PaymentLinksEditorState extends State<PaymentLinksEditor> {
  final _monthly = TextEditingController();
  final _yearly = TextEditingController();
  final _proMonthly = TextEditingController();
  final _proYearly = TextEditingController();

  List<TextEditingController> get _fields => [
    _monthly,
    _yearly,
    _proMonthly,
    _proYearly,
  ];

  /// The links the fields were last filled from.
  PaymentLinks? _shown;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.payments.addListener(_fill);
    _fill();
    if (widget.payments.links == null) widget.payments.load();
  }

  @override
  void dispose() {
    widget.payments.removeListener(_fill);
    for (final field in _fields) {
      field.dispose();
    }
    super.dispose();
  }

  /// Shows the service's links, unless they're what's shown already (so
  /// an edit in progress stays).
  void _fill() {
    final links = widget.payments.links;
    if (links == null || links == _shown) return;
    setState(() {
      _shown = links;
      _monthly.text = links.monthly;
      _yearly.text = links.yearly;
      _proMonthly.text = links.proMonthly;
      _proYearly.text = links.proYearly;
    });
  }

  /// Empty, or a Stripe HTTPS link (the API checks it too).
  static bool _valid(String text) {
    final link = text.trim();
    if (link.isEmpty) return true;
    final url = Uri.tryParse(link);
    return url != null && PremiumCheckout.isStripe(url) && url.query.isEmpty;
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    setState(() => _saving = true);
    try {
      await widget.payments.save(
        monthly: _monthly.text,
        yearly: _yearly.text,
        proMonthly: _proMonthly.text,
        proYearly: _proYearly.text,
      );
      messenger.showSnackBar(SnackBar(content: Text(l10n.authPaymentsSaved)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.authPaymentsSaveFailed('$e'))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    final links = widget.payments.links;
    final valid = _fields.every((field) => _valid(field.text));
    InputDecoration field(String label, TextEditingController c) =>
        InputDecoration(
          labelText: label,
          hintText: 'https://buy.stripe.com/…',
          border: const OutlineInputBorder(),
          errorText: _valid(c.text) ? null : l10n.authPaymentsInvalid,
        );
    return Column(
      key: const Key('admin-payments'),
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(l10n.authPaymentsTitle, style: theme.textTheme.titleLarge),
        Text(l10n.authPaymentsIntro, style: muted),
        if (links == null)
          Text(l10n.authPaymentsUnavailable, style: muted)
        else if (!links.saved)
          Text(
            l10n.authPaymentsDefaults,
            key: const Key('admin-payments-defaults'),
            style: muted,
          ),
        for (final (key, controller, label) in [
          ('admin-payments-monthly', _monthly, l10n.authPaymentsMonthly),
          ('admin-payments-yearly', _yearly, l10n.authPaymentsYearly),
          (
            'admin-payments-pro-monthly',
            _proMonthly,
            l10n.authPaymentsProMonthly,
          ),
          ('admin-payments-pro-yearly', _proYearly, l10n.authPaymentsProYearly),
        ])
          TextField(
            key: Key(key),
            controller: controller,
            enabled: links != null && !_saving,
            keyboardType: TextInputType.url,
            decoration: field(label, controller),
            onChanged: (_) => setState(() {}),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            key: const Key('admin-payments-save'),
            icon: const Icon(Icons.save_outlined),
            label: Text(l10n.authPaymentsSave),
            onPressed: links != null && valid && !_saving ? _save : null,
          ),
        ),
      ],
    );
  }
}
