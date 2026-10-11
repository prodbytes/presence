import '../cloud/device_slots.dart';

/// Where a free member upgrades to Premium: a Stripe Payment Link of the
/// Premium subscription (monthly, US$20 a month with the first week free,
/// or yearly), on every platform, in the browser.
///
/// The link is a Stripe Payment Link on the Stripe account rbacr syncs
/// subscriptions from (rbacr's Q1 to Q3): once the checkout's subscription
/// is `trialing` or `active`, rbacr grants the `presence` system's
/// subscriber role (`premium`) to the customer's email. rbacr matches by
/// email only, so the checkout's email is the signed-in account's,
/// prefilled and locked.
///
/// The links come from the payments API (`PaymentsService`), which admins
/// set in the Admin tab. Without one, or not an HTTPS link on stripe.com,
/// the button opens nu01.com ([DeviceSlots.signUp]).
abstract final class PremiumCheckout {
  /// The checkout of [link] for [email] (prefilled and locked) and
  /// [profileId] (Stripe's `client_reference_id`, for support); nu01.com
  /// without a usable link.
  static Uri checkout({String? email, String? profileId, String? link}) {
    final base = Uri.tryParse((link ?? '').trim());
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
