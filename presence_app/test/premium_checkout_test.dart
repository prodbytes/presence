import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/premium_checkout.dart';

void main() {
  const link = 'https://buy.stripe.com/test_00abc';

  group('PremiumCheckout.checkout', () {
    test('prefills and locks the email, and names the profile', () {
      final url = PremiumCheckout.checkout(
        email: 'ana@example.com',
        profileId: 'automatic_paranoid_axolotl',
        link: link,
      );
      expect(url.origin, 'https://buy.stripe.com');
      expect(url.path, '/test_00abc');
      expect(url.queryParameters, {
        'prefilled_email': 'ana@example.com',
        'locked_prefilled_email': 'true',
        'client_reference_id': 'automatic_paranoid_axolotl',
      });
    });

    test('keeps the link\'s own parameters', () {
      final url = PremiumCheckout.checkout(
        email: 'ana+cams@example.com',
        link: '$link?locale=pt-BR',
      );
      expect(url.queryParameters['locale'], 'pt-BR');
      expect(url.queryParameters['prefilled_email'], 'ana+cams@example.com');
      expect(url.queryParameters.containsKey('client_reference_id'), isFalse);
    });

    test('the bare link without an account', () {
      expect(PremiumCheckout.checkout(link: link), Uri.parse(link));
    });

    test('leaves out a reference Stripe would refuse', () {
      final url = PremiumCheckout.checkout(profileId: 'a b/c', link: link);
      expect(url.queryParameters.containsKey('client_reference_id'), isFalse);
    });

    test('nu01.com without a Stripe HTTPS link', () {
      final nu01 = Uri.parse('https://nu01.com');
      // No link.
      expect(PremiumCheckout.checkout(email: 'ana@example.com'), nu01);
      for (final bad in [
        '',
        'http://buy.stripe.com/x',
        'https://buy.stripe.com.evil.example/x',
        'https://evilstripe.com/x',
        'javascript:alert(1)',
      ]) {
        expect(PremiumCheckout.checkout(link: bad), nu01, reason: bad);
      }
    });
  });
}
