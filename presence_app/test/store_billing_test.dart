import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:presence_app/auth/plan_notice.dart';
import 'package:presence_app/auth/store_billing.dart';
import 'package:presence_app/cloud/device_slots.dart';
import 'package:presence_app/events.dart';

import 'fakes.dart';

const monthly = StoreProducts.monthly;
const yearly = StoreProducts.yearly;
const accountToken = '0b7c9a3e-2f1d-4c6b-9e8a-5d4c3b2a1f00';

/// The App Store or Google Play, faked: the products it offers, what it
/// reports on the purchase stream, and what the app asked of it.
class FakeStorePlatform extends InAppPurchasePlatform {
  FakeStorePlatform({this.products = const [], this.owned = const []});

  final List<ProductDetails> products;

  /// What a restore reports (the current subscriptions).
  List<PurchaseDetails> owned;

  bool storeAvailable = true;
  final purchases = StreamController<List<PurchaseDetails>>.broadcast();
  final bought = <PurchaseParam>[];
  final completed = <String?>[];
  final restoredFor = <String?>[];

  /// What a purchase reports; null: nothing (the sheet is still open).
  PurchaseDetails Function(PurchaseParam)? onBuy;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => purchases.stream;

  @override
  Future<bool> isAvailable() async => storeAvailable;

  @override
  Future<ProductDetailsResponse> queryProductDetails(
    Set<String> identifiers,
  ) async => ProductDetailsResponse(
    productDetails: [
      for (final p in products)
        if (identifiers.contains(p.id)) p,
    ],
    notFoundIDs: const [],
  );

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    bought.add(purchaseParam);
    if (onBuy case final reply?) {
      scheduleMicrotask(() => purchases.add([reply(purchaseParam)]));
    }
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    completed.add(purchase.purchaseID);
  }

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    restoredFor.add(applicationUserName);
    if (owned.isNotEmpty) purchases.add(owned);
  }
}

/// A purchase as the store reports it.
PurchaseDetails purchase(
  String productId, {
  PurchaseStatus status = PurchaseStatus.purchased,
  String id = 'GPA.1234',
  String data = 'purchase-token-123',
  bool pending = true,
}) => PurchaseDetails(
  purchaseID: id,
  productID: productId,
  verificationData: PurchaseVerificationData(
    localVerificationData: '{}',
    serverVerificationData: data,
    source: 'google_play',
  ),
  transactionDate: '1790000000000',
  status: status,
)..pendingCompletePurchase = pending;

/// Google Play's details of a subscription: its base plan (US$19.99 a
/// month) and, with [trial], a one-week free trial offer.
List<GooglePlayProductDetails> playSubscription(
  String id, {
  String price = r'US$19.99',
  String period = 'P1M',
  bool trial = false,
}) {
  PricingPhaseWrapper phase(
    String price,
    int micros,
    String period,
    RecurrenceMode mode,
  ) => PricingPhaseWrapper(
    billingCycleCount: mode == RecurrenceMode.infiniteRecurring ? 0 : 1,
    billingPeriod: period,
    formattedPrice: price,
    priceAmountMicros: micros,
    priceCurrencyCode: 'USD',
    recurrenceMode: mode,
  );
  final recurring = phase(
    price,
    19990000,
    period,
    RecurrenceMode.infiniteRecurring,
  );
  return GooglePlayProductDetails.fromProductDetails(
    ProductDetailsWrapper(
      description: 'Premium',
      name: 'Premium',
      productId: id,
      productType: ProductType.subs,
      title: 'Premium (Presence)',
      subscriptionOfferDetails: [
        SubscriptionOfferDetailsWrapper(
          basePlanId: 'base',
          offerTags: const [],
          offerIdToken: 'base-token',
          pricingPhases: [recurring],
        ),
        if (trial)
          SubscriptionOfferDetailsWrapper(
            basePlanId: 'base',
            offerId: 'trial',
            offerTags: const [],
            offerIdToken: 'trial-token',
            pricingPhases: [
              phase('Free', 0, 'P1W', RecurrenceMode.finiteRecurring),
              recurring,
            ],
          ),
      ],
    ),
  );
}

/// The payments API's store routes, faked.
class FakeStoreClient implements StoreClient {
  StoreStatus answer = const StoreStatus(
    ios: true,
    android: true,
    accountToken: accountToken,
  );

  /// The status verify answers with (200: verified).
  int verifyStatus = 200;
  final verified = <String>[];

  @override
  Future<StoreStatus> status(String idToken) async => answer;

  @override
  Future<void> verify(
    String idToken, {
    required String platform,
    required String productId,
    required String verificationData,
  }) async {
    verified.add('$platform $productId $verificationData');
    if (verifyStatus != 200) throw StoreVerifyException(verifyStatus);
  }
}

void main() {
  late FakeStorePlatform store;
  late FakeStoreClient client;
  late FakeAuthService auth;
  var rolesChecked = 0;

  StoreBilling makeBilling({
    PurchaseChannel channel = PurchaseChannel.googlePlay,
    Duration recheckEvery = const Duration(days: 1),
  }) {
    final billing = StoreBilling(
      auth: auth,
      client: client,
      channel: channel,
      platform: () => store,
      onVerified: () async => rolesChecked++,
      recheckEvery: recheckEvery,
      trialEligible: (_) async => true,
    );
    addTearDown(billing.dispose);
    return billing;
  }

  setUp(() {
    store = FakeStorePlatform(
      products: [
        ...playSubscription(monthly, trial: true),
        ...playSubscription(yearly, price: r'US$199.99', period: 'P1Y'),
      ],
    );
    client = FakeStoreClient();
    auth = FakeAuthService();
    rolesChecked = 0;
  });

  group('StorePlan', () {
    test("takes Google Play's price, period and trial", () {
      final plans = StorePlan.fromDetails(store.products);
      expect(plans.map((p) => p.productId), [monthly, yearly]);
      expect(plans.first.price, r'US$19.99');
      expect(plans.first.period, const StorePeriod(1, PeriodUnit.month));
      expect(plans.first.trial, const StorePeriod(1, PeriodUnit.week));
      // The trial's offer, so buying it gets the trial.
      expect(
        (plans.first.details as GooglePlayProductDetails).offerToken,
        'trial-token',
      );
      expect(plans.last.period, const StorePeriod(1, PeriodUnit.year));
      expect(plans.last.trial, isNull);
    });

    test('other details: the price, and the period by the ID', () {
      final plans = StorePlan.fromDetails([
        ProductDetails(
          id: yearly,
          title: 'Premium yearly',
          description: '',
          price: '€99',
          rawPrice: 99,
          currencyCode: 'EUR',
        ),
        ProductDetails(
          id: 'something.else',
          title: '',
          description: '',
          price: '1',
          rawPrice: 1,
          currencyCode: 'EUR',
        ),
      ]);
      expect(plans.single.price, '€99');
      expect(plans.single.period, const StorePeriod(1, PeriodUnit.year));
    });

    test('ISO periods', () {
      expect(StorePeriod.parse('P7D'), const StorePeriod(7, PeriodUnit.day));
      expect(StorePeriod.parse('P3M'), const StorePeriod(3, PeriodUnit.month));
      expect(StorePeriod.parse('P1Y2M'), isNull);
    });
  });

  test('manage links', () {
    expect(
      StoreProducts.manage(PurchaseChannel.appStore),
      Uri.parse('https://apps.apple.com/account/subscriptions'),
    );
    expect(
      StoreProducts.manage(PurchaseChannel.googlePlay, productId: monthly),
      Uri.parse(
        'https://play.google.com/store/account/subscriptions'
        '?sku=presence.premium.monthly&package=com.nu01.presence',
      ),
    );
  });

  group('StoreBilling', () {
    test('at sign-in: the plans, and the current subscriptions verified '
        'again', () async {
      store.owned = [purchase(monthly, status: PurchaseStatus.restored)];
      final billing = makeBilling();
      expect(billing.plans, isEmpty);
      await auth.signIn();
      await pumpEventQueue();
      expect(billing.available, isTrue);
      expect(billing.plans, hasLength(2));
      expect(store.restoredFor, [accountToken]);
      expect(client.verified, ['android $monthly purchase-token-123']);
      // Completed (acknowledged) only after the server verified it.
      expect(store.completed, ['GPA.1234']);
      expect(billing.owned, monthly);
      expect(rolesChecked, 1);
      // Quietly: nothing to say.
      expect(billing.message, isNull);
    });

    test('buys with the account token, and completes once verified', () async {
      store.onBuy = (param) => purchase(param.productDetails.id);
      final billing = makeBilling();
      await auth.signIn();
      await pumpEventQueue();
      await billing.buy(billing.plans.first);
      expect(billing.busy, isTrue);
      await pumpEventQueue();
      expect(store.bought.single.applicationUserName, accountToken);
      expect(store.bought.single.productDetails.id, monthly);
      expect(client.verified, ['android $monthly purchase-token-123']);
      expect(store.completed, ['GPA.1234']);
      expect(billing.message, StoreMessage.purchased);
      expect(billing.busy, isFalse);
      expect(rolesChecked, 1);
    });

    test("isn't completed when the server didn't verify it", () async {
      store.onBuy = (param) => purchase(param.productDetails.id);
      final billing = makeBilling();
      await auth.signIn();
      await pumpEventQueue();
      for (final (status, message) in [
        (502, StoreMessage.failed),
        (503, StoreMessage.failed),
        (409, StoreMessage.otherAccount),
        (400, StoreMessage.notVerified),
      ]) {
        client.verifyStatus = status;
        await billing.buy(billing.plans.first);
        await pumpEventQueue();
        expect(billing.message, message, reason: '$status');
      }
      expect(store.completed, isEmpty);
      expect(rolesChecked, 0);
    });

    test('a pending purchase says so, and a cancelled one nothing', () async {
      final billing = makeBilling();
      await auth.signIn();
      await pumpEventQueue();
      store.purchases.add([purchase(monthly, status: PurchaseStatus.pending)]);
      await pumpEventQueue();
      expect(billing.message, StoreMessage.pending);
      store.purchases.add([
        purchase(monthly, status: PurchaseStatus.canceled, pending: false),
      ]);
      await pumpEventQueue();
      expect(client.verified, isEmpty);
    });

    test('Restore purchases says what it found', () async {
      final billing = makeBilling();
      await auth.signIn();
      await pumpEventQueue();
      await billing.restore();
      expect(billing.message, StoreMessage.nothingToRestore);

      store.owned = [purchase(yearly, status: PurchaseStatus.restored)];
      await billing.restore();
      expect(billing.message, StoreMessage.restored);
      expect(billing.owned, yearly);
    });

    test('checks again while running, so renewals extend Premium', () async {
      store.owned = [purchase(monthly, status: PurchaseStatus.restored)];
      makeBilling(recheckEvery: const Duration(milliseconds: 40));
      await auth.signIn();
      await Future<void>.delayed(const Duration(milliseconds: 130));
      // At sign-in, then at least twice more.
      expect(store.restoredFor.length, greaterThanOrEqualTo(3));
      expect(client.verified.length, store.restoredFor.length);
    });

    test("nothing to buy when the API doesn't verify this store", () async {
      client.answer = const StoreStatus(ios: true, accountToken: accountToken);
      final billing = makeBilling();
      await auth.signIn();
      await pumpEventQueue();
      expect(billing.available, isFalse);
      expect(billing.plans, isEmpty);
      expect(store.restoredFor, isEmpty);
    });

    test('forgets the account at sign-out', () async {
      store.owned = [purchase(monthly, status: PurchaseStatus.restored)];
      final billing = makeBilling();
      await auth.signIn();
      await pumpEventQueue();
      await auth.signOut();
      expect(billing.plans, isEmpty);
      expect(billing.owned, isNull);
      // A purchase reported while signed out stays unfinished.
      store.purchases.add([purchase(monthly, id: 'GPA.5678')]);
      await pumpEventQueue();
      expect(store.completed, ['GPA.1234']);
    });

    test('nothing on the web or other platforms', () async {
      final billing = StoreBilling(
        auth: auth,
        client: client,
        channel: PurchaseChannel.none,
        platform: () => throw StateError('no store here'),
      );
      addTearDown(billing.dispose);
      await auth.signIn();
      await pumpEventQueue();
      expect(billing.plans, isEmpty);
    });
  });

  test('HttpStoreClient', () async {
    final requests = <http.Request>[];
    final client = HttpStoreClient(
      Uri.parse('https://presence.nu01.com/'),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/api/payments/store') {
          return http.Response(
            jsonEncode({
              'ios': true,
              'android': false,
              'accountToken': accountToken,
            }),
            200,
          );
        }
        return http.Response('{"error":"x"}', 409);
      }),
    );
    final status = await client.status('id-token');
    expect(status.enabled(PurchaseChannel.appStore), isTrue);
    expect(status.enabled(PurchaseChannel.googlePlay), isFalse);
    await expectLater(
      client.verify(
        'id-token',
        platform: 'ios',
        productId: monthly,
        verificationData: 'jws',
      ),
      throwsA(isA<StoreVerifyException>().having((e) => e.status, 's', 409)),
    );
    expect(requests.last.headers['authorization'], 'Bearer id-token');
    expect(jsonDecode(requests.last.body), {
      'platform': 'ios',
      'productId': monthly,
      'verificationData': 'jws',
    });
  });

  group('the plan box on iOS and Android', () {
    // Made outside the test's fake clock, whose timers must all be done by
    // its end: the daily re-check's timer isn't.
    Future<StoreBilling> signedIn(
      WidgetTester tester, {
      PurchaseChannel channel = PurchaseChannel.googlePlay,
      bool signIn = true,
    }) async => (await tester.runAsync(() async {
      final billing = makeBilling(channel: channel);
      if (signIn) {
        await auth.signIn();
        await pumpEventQueue();
      }
      return billing;
    }))!;

    Future<List<Uri>> show(
      WidgetTester tester, {
      required bool premium,
      StoreBilling? billing,
      PurchaseChannel channel = PurchaseChannel.googlePlay,
    }) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PlanNotice(
                premium: premium,
                email: 'ana@example.com',
                onCheckAgain: () async {},
                store: billing,
                channel: channel,
                openLink: (url) async {
                  opened.add(url);
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      return opened;
    }

    testWidgets("the store's plans, never Stripe or a web price", (
      tester,
    ) async {
      store.onBuy = (param) => purchase(param.productDetails.id);
      final billing = await signedIn(tester);
      final opened = await show(tester, premium: false, billing: billing);
      expect(find.textContaining(r'US$20'), findsNothing);
      expect(find.textContaining('Stripe'), findsNothing);
      expect(find.byKey(const Key('plan-upgrade')), findsNothing);
      expect(find.text(r'Premium monthly: US$19.99 / month'), findsOneWidget);
      expect(find.text(r'Premium yearly: US$199.99 / year'), findsOneWidget);
      expect(find.text(r'1 week free, then US$19.99 / month.'), findsOneWidget);
      expect(find.textContaining('renew automatically'), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-terms')));
      await tester.tap(find.byKey(const Key('store-privacy')));
      await tester.tap(find.byKey(const Key('store-manage')));
      expect(opened, [
        Uri.parse('https://presence.nu01.com/tos'),
        Uri.parse('https://presence.nu01.com/privacy'),
        Uri.parse(
          'https://play.google.com/store/account/subscriptions'
          '?package=com.nu01.presence',
        ),
      ]);
      expect(opened.any((u) => u.host == 'nu01.com'), isFalse);

      await tester.tap(find.byKey(const Key('store-buy-$yearly')));
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(store.bought.single.productDetails.id, yearly);
      expect(find.text('Thank you! Premium is on.'), findsOneWidget);
    });

    testWidgets('Restore purchases', (tester) async {
      final billing = await signedIn(tester);
      await show(tester, premium: false, billing: billing);
      await tester.tap(find.byKey(const Key('store-restore')));
      await tester.pumpAndSettle();
      expect(find.text('No active subscription to restore.'), findsOneWidget);
    });

    testWidgets('Premium from the store: Manage subscription', (tester) async {
      store.owned = [purchase(monthly, status: PurchaseStatus.restored)];
      final billing = await signedIn(tester, channel: PurchaseChannel.appStore);
      final opened = await show(
        tester,
        premium: true,
        billing: billing,
        channel: PurchaseChannel.appStore,
      );
      await tester.tap(find.byKey(const Key('store-manage')));
      expect(opened, [
        Uri.parse('https://apps.apple.com/account/subscriptions'),
      ]);
    });

    testWidgets('Premium some other way: nothing to manage here', (
      tester,
    ) async {
      final billing = await signedIn(tester, signIn: false);
      await show(tester, premium: true, billing: billing);
      expect(find.byKey(const Key('store-manage')), findsNothing);
      expect(find.text('Premium'), findsOneWidget);
    });

    testWidgets('elsewhere (Linux): no purchase buttons', (tester) async {
      await show(tester, premium: false, channel: PurchaseChannel.none);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.textContaining(r'US$20'), findsNothing);
      expect(find.byKey(const Key('plan-check-again')), findsOneWidget);
    });
  });

  group('the Monitoring notice on iOS and Android', () {
    testWidgets('Upgrade goes to the plans, never to Stripe', (tester) async {
      final bus = StreamController<AppEvent>.broadcast();
      final log = EventLog(bus.stream);
      addTearDown(() {
        log.dispose();
        bus.close();
      });
      const slots = DeviceSlots(limit: 2, devices: ['a_b_c', 'd_e_f', 'g_h_i']);
      log.visibleDevices = slots.visibleFrom('g_h_i');
      var upgraded = 0;
      final opened = <Uri>[];
      Future<void> show({VoidCallback? onUpgrade, PurchaseChannel? channel}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: DeviceLimitNotice(
                  log: log,
                  slots: slots,
                  profileId: 'automatic_paranoid_axolotl',
                  thisDevice: 'g_h_i',
                  channel: channel ?? PurchaseChannel.googlePlay,
                  onUpgrade: onUpgrade,
                  openLink: (url) async {
                    opened.add(url);
                    return true;
                  },
                ),
              ),
            ),
          );
      await show(onUpgrade: () => upgraded++);
      await tester.tap(find.byKey(const Key('device-limit-upgrade')));
      expect(upgraded, 1);
      expect(opened, isEmpty);

      await show();
      expect(find.byKey(const Key('device-limit-upgrade')), findsNothing);
      await show(channel: PurchaseChannel.none, onUpgrade: () => upgraded++);
      expect(find.byKey(const Key('device-limit-upgrade')), findsNothing);
    });
  });
}
