import 'dart:async';

import 'package:presence_app/auth/store_billing.dart';
import 'package:presence_app/crypto/media_seal.dart';

/// Every test file seals media with a fixed test key, as the app does with
/// its device's key once storage opens.
///
/// And sells Premium as the web does (Stripe): the test platform is
/// Android, but only the tests that ask for a store (a fake one) get it.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  MediaSeal.instance = MediaSeal.forTests();
  PurchaseChannel.debugOverride = PurchaseChannel.stripe;
  await testMain();
}
