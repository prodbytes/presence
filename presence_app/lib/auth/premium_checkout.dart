import '../cloud/device_slots.dart';

/// Where a free member upgrades to Premium: the Stripe Payment Link of the
/// Premium subscription (US$20 a month, the first week free), on every
/// platform, in the browser.
///
/// The link is a Stripe Payment Link on the Stripe account rbacr syncs
/// subscriptions from (rbacr's Q1 to Q3): once the checkout's subscription
/// is `trialing` or `active`, rbacr grants the `presence` system's
/// subscriber role (`premium`) to the customer's email. rbacr matches by
/// email only, so the checkout's email is the signed-in account's,
/// prefilled and locked.
///
/// Set at build time (`STRIPE_PAYMENT_LINK`, `scripts/dart-defines.sh`).
/// Unset, or not an HTTPS link on stripe.com, the button opens nu01.com
/// ([DeviceSlots.signUp]), as before.
abstract final class PremiumCheckout {
  static const String _link = String.fromEnvironment('STRIPE_PAYMENT_LINK');

  /// What Premium costs, as the button says it. The price itself is the
  /// Payment Link's, set in Stripe.
  static const price = r'US$20 a month, the first week free';

  /// The checkout for [email] (prefilled and locked) and [profileId]
  /// (Stripe's `client_reference_id`, for support), on [link]
  /// (`STRIPE_PAYMENT_LINK` by default); nu01.com without a usable link.
  static Uri checkout({String? email, String? profileId, String? link}) {
    final base = Uri.tryParse((link ?? _link).trim());
    if (base == null || !isStripe(base)) return DeviceSlots.signUp;
    final address = email?.trim() ?? '';
    final reference = profileId?.trim() ?? '';
    final query = {
      ...base.queryParameters,
      if (address.isNotEmpty) ...{
        'prefilled_email': address,
        'locked_prefilled_email': 'true',
      },
      // Stripe takes letters, digits, '-' and '_', up to 200.
      if (RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(reference))
        'client_reference_id': reference,
    };
    return query.isEmpty ? base : base.replace(queryParameters: query);
  }

  /// Whether [url] is an HTTPS page of Stripe's (`buy.stripe.com`, or
  /// another stripe.com host).
  static bool isStripe(Uri url) =>
      url.scheme == 'https' &&
      (url.host == 'stripe.com' || url.host.endsWith('.stripe.com'));
}
