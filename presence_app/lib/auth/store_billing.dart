import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

import 'auth_service.dart';

/// Where this build sells Premium: Stripe on the web, the App Store on
/// iOS and Google Play on Android (their rules: App Store 3.1.1, Play's
/// payments policy, so the mobile apps never show, link to or mention
/// Stripe or web prices), and nowhere elsewhere (Linux, macOS, ...).
enum PurchaseChannel {
  stripe,
  appStore,
  googlePlay,
  none;

  /// This build's channel ([debugOverride] when set).
  static PurchaseChannel get current {
    if (debugOverride case final channel?) return channel;
    if (kIsWeb) return stripe;
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => appStore,
      TargetPlatform.android => googlePlay,
      _ => none,
    };
  }

  /// Replaces [current] (tests: the test platform says Android, but only
  /// the tests that ask for a store should get one).
  static PurchaseChannel? debugOverride;

  /// Whether Premium is bought in an app store here.
  bool get isStore => this == appStore || this == googlePlay;

  /// The payments API's name for the store (`ios`, `android`).
  String get platform => this == appStore ? 'ios' : 'android';

  /// [storeRenews]'s select value.
  String get storeName => this == appStore ? 'apple' : 'google';
}

/// The Premium subscriptions: the same product IDs in both stores.
abstract final class StoreProducts {
  static const monthly = 'presence.premium.monthly';
  static const yearly = 'presence.premium.yearly';
  static const all = {monthly, yearly};

  /// The app's bundle (iOS) and package (Android) ID.
  static const appId = 'com.nu01.presence';

  /// Where the user manages (or cancels) store subscriptions: the App
  /// Store's subscriptions page, or Google Play's for [productId].
  static Uri manage(PurchaseChannel channel, {String? productId}) =>
      channel == PurchaseChannel.appStore
      ? Uri.parse('https://apps.apple.com/account/subscriptions')
      : Uri.https('play.google.com', '/store/account/subscriptions', {
          'sku': ?productId,
          'package': appId,
        });
}

enum PeriodUnit { day, week, month, year }

/// A subscription's billing or trial period, as the store gives it.
@immutable
class StorePeriod {
  const StorePeriod(this.count, this.unit);

  final int count;
  final PeriodUnit unit;

  /// An ISO 8601 period as Google Play gives it (`P1W`, `P7D`, `P1M`,
  /// `P1Y`); null for anything else.
  static StorePeriod? parse(String iso) {
    final match = RegExp(r'^P(\d{1,3})([DWMY])$').firstMatch(iso);
    if (match == null) return null;
    final count = int.parse(match.group(1)!);
    return StorePeriod(count, switch (match.group(2)) {
      'D' => PeriodUnit.day,
      'W' => PeriodUnit.week,
      'M' => PeriodUnit.month,
      _ => PeriodUnit.year,
    });
  }

  @override
  bool operator ==(Object other) =>
      other is StorePeriod && other.count == count && other.unit == unit;

  @override
  int get hashCode => Object.hash(count, unit);

  @override
  String toString() => 'StorePeriod($count ${unit.name})';
}

/// A Premium subscription as the store offers it to this user: its
/// localized price, billing period and free trial (when there's one and
/// the user may have it), never hardcoded.
@immutable
class StorePlan {
  const StorePlan({
    required this.details,
    required this.price,
    this.period,
    this.trial,
  });

  /// What the store gave, to buy it with.
  final ProductDetails details;

  String get productId => details.id;

  /// The recurring price, formatted by the store (`US$19.99`, `R$ 99,90`).
  final String price;

  /// How often it renews; null when the store didn't say.
  final StorePeriod? period;

  /// The free trial, or null.
  final StorePeriod? trial;

  /// The plans in [details], monthly first; for Google Play, which lists
  /// a subscription once per offer, the free trial's offer when there's
  /// one (Play lists only offers the user may have), else the base plan.
  /// [trialEligible] answers whether the App Store will give a product's
  /// introductory offer to this user.
  static List<StorePlan> fromDetails(
    Iterable<ProductDetails> details, {
    Set<String> trialEligible = const {},
  }) {
    final plans = <String, StorePlan>{};
    for (final d in details) {
      if (!StoreProducts.all.contains(d.id)) continue;
      final plan = _plan(d, trialEligible.contains(d.id));
      final previous = plans[d.id];
      if (previous == null || (previous.trial == null && plan.trial != null)) {
        plans[d.id] = plan;
      }
    }
    return [
      for (final id in [StoreProducts.monthly, StoreProducts.yearly])
        ?plans[id],
    ];
  }

  static StorePlan _plan(ProductDetails d, bool trialEligible) {
    if (d is GooglePlayProductDetails) {
      final index = d.subscriptionIndex;
      final offers = d.productDetails.subscriptionOfferDetails;
      if (index != null && offers != null && index < offers.length) {
        final phases = offers[index].pricingPhases;
        final recurring = phases.lastWhere(
          (p) => p.recurrenceMode == RecurrenceMode.infiniteRecurring,
          orElse: () => phases.last,
        );
        final free = phases.length > 1 && phases.first.priceAmountMicros == 0
            ? phases.first
            : null;
        return StorePlan(
          details: d,
          price: recurring.formattedPrice,
          period: StorePeriod.parse(recurring.billingPeriod),
          trial: free == null
              ? null
              : switch (StorePeriod.parse(free.billingPeriod)) {
                  final p? => StorePeriod(
                    p.count *
                        (free.billingCycleCount < 1
                            ? 1
                            : free.billingCycleCount),
                    p.unit,
                  ),
                  null => null,
                },
        );
      }
    }
    if (d is AppStoreProduct2Details) {
      final subscription = d.sk2Product.subscription;
      final intro = subscription?.promotionalOffers
          .where(
            (o) =>
                o.type == SK2SubscriptionOfferType.introductory &&
                o.paymentMode == SK2SubscriptionOfferPaymentMode.freeTrial,
          )
          .firstOrNull;
      return StorePlan(
        details: d,
        price: d.price,
        period: subscription == null
            ? null
            : _apple(subscription.subscriptionPeriod, 1),
        trial: intro != null && trialEligible
            ? _apple(intro.period, intro.periodCount)
            : null,
      );
    }
    // Any other store's details: the price only, the period from the ID.
    return StorePlan(
      details: d,
      price: d.price,
      period: switch (d.id) {
        StoreProducts.monthly => const StorePeriod(1, PeriodUnit.month),
        StoreProducts.yearly => const StorePeriod(1, PeriodUnit.year),
        _ => null,
      },
    );
  }

  static StorePeriod _apple(SK2SubscriptionPeriod period, int times) =>
      StorePeriod(period.value * (times < 1 ? 1 : times), switch (period.unit) {
        SK2SubscriptionPeriodUnit.day => PeriodUnit.day,
        SK2SubscriptionPeriodUnit.week => PeriodUnit.week,
        SK2SubscriptionPeriodUnit.month => PeriodUnit.month,
        SK2SubscriptionPeriodUnit.year => PeriodUnit.year,
      });
}

/// Which stores the payments API verifies, and the account's token (a
/// random UUID, not personal data) that binds purchases to the account:
/// Apple's `appAccountToken`, Google's `obfuscatedAccountId`.
@immutable
class StoreStatus {
  const StoreStatus({
    this.ios = false,
    this.android = false,
    this.accountToken,
  });

  factory StoreStatus.fromJson(Map<String, Object?> json) => StoreStatus(
    ios: json['ios'] == true,
    android: json['android'] == true,
    accountToken: switch (json['accountToken']) {
      final String token when RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(token) =>
        token,
      _ => null,
    },
  );

  final bool ios;
  final bool android;
  final String? accountToken;

  bool enabled(PurchaseChannel channel) => switch (channel) {
    PurchaseChannel.appStore => ios && accountToken != null,
    PurchaseChannel.googlePlay => android && accountToken != null,
    _ => false,
  };
}

/// A refusal of the payments API (400: the store didn't vouch for it; 409:
/// another account's; 502/503: try later).
class StoreVerifyException implements Exception {
  const StoreVerifyException(this.status);
  final int status;

  @override
  String toString() => 'StoreVerifyException($status)';
}

/// The payments API's store routes, with the user's ID token.
abstract class StoreClient {
  /// `GET /api/payments/store`.
  Future<StoreStatus> status(String idToken);

  /// `POST /api/payments/store/verify`: the server checks the purchase with
  /// the store and grants Premium; throws [StoreVerifyException] when not.
  Future<void> verify(
    String idToken, {
    required String platform,
    required String productId,
    required String verificationData,
  });

  /// `POST /api/payments/free`: Join free, the account gets the free
  /// membership (rbacr's `free`; a no-op for a member); throws
  /// [StoreVerifyException] when not.
  Future<void> joinFree(String idToken);
}

/// The real client, under the site's `/api/payments/` (`ApiConfig`).
class HttpStoreClient implements StoreClient {
  HttpStoreClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  @override
  Future<StoreStatus> status(String idToken) async {
    final response = await _client.get(
      base.resolve('/api/payments/store'),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) {
      throw StoreVerifyException(response.statusCode);
    }
    return StoreStatus.fromJson(
      (jsonDecode(response.body) as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<void> verify(
    String idToken, {
    required String platform,
    required String productId,
    required String verificationData,
  }) async {
    final response = await _client.post(
      base.resolve('/api/payments/store/verify'),
      headers: {
        'authorization': 'Bearer $idToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'platform': platform,
        'productId': productId,
        'verificationData': verificationData,
      }),
    );
    if (response.statusCode != 200) {
      throw StoreVerifyException(response.statusCode);
    }
  }

  @override
  Future<void> joinFree(String idToken) async {
    final response = await _client.post(
      base.resolve('/api/payments/free'),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) {
      throw StoreVerifyException(response.statusCode);
    }
  }
}

/// What the store box says after something happened.
enum StoreMessage {
  pending,
  purchased,
  restored,
  nothingToRestore,
  otherAccount,
  notVerified,
  failed,
  purchaseFailed,
}

/// Premium in the App Store or Google Play, for the signed-in account:
///
/// - at sign-in, asks the payments API which stores it verifies and the
///   account's token, then the store for the plans ([plans]);
/// - [buy] starts the store's purchase with the account's token on it;
/// - every purchase or restored subscription the store reports goes to the
///   payments API, which verifies it with the store and grants Premium;
///   only then is the purchase completed (finished, acknowledged), so a
///   purchase that wasn't verified comes back to be tried again;
/// - at sign-in and every [recheckEvery] while running (unattended
///   phones), it restores the current subscriptions quietly and verifies
///   them again, so renewals extend Premium;
/// - [restore] does that on request (Restore purchases).
///
/// [onVerified] runs after each verified purchase (the roles check, so the
/// app turns Premium).
class StoreBilling extends ChangeNotifier {
  StoreBilling({
    required this.auth,
    required this.client,
    required this.channel,
    InAppPurchasePlatform Function()? platform,
    this.onVerified,
    this.recheckEvery = const Duration(days: 1),
    Future<bool> Function(String productId)? trialEligible,
  }) : _platform = platform ?? _defaultPlatform,
       _trialEligible = trialEligible ?? _appStoreTrialEligible {
    if (!channel.isStore) return;
    _purchases = _store.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => debugPrint('Presence: store purchases: $e'),
    );
    _recheck = Timer.periodic(recheckEvery, (_) => _restore(quiet: true));
    auth.addListener(_onAuth);
    _onAuth();
  }

  final AuthService auth;
  final StoreClient client;
  final PurchaseChannel channel;
  final Future<void> Function()? onVerified;
  final Duration recheckEvery;
  final InAppPurchasePlatform Function() _platform;
  final Future<bool> Function(String productId) _trialEligible;

  static InAppPurchasePlatform _defaultPlatform() {
    // Registers the platform's implementation on first use.
    InAppPurchase.instance;
    return InAppPurchasePlatform.instance;
  }

  static Future<bool> _appStoreTrialEligible(String productId) async {
    try {
      return await SK2Product.isIntroductoryOfferEligible(productId);
    } catch (_) {
      return false;
    }
  }

  InAppPurchasePlatform get _store => _platform();

  StreamSubscription<List<PurchaseDetails>>? _purchases;
  Timer? _recheck;
  String? _for;
  StoreStatus? _status;
  bool _disposed = false;

  /// The plans the store offers; empty while loading or unavailable.
  List<StorePlan> get plans => _plans;
  List<StorePlan> _plans = const [];

  /// Whether the plans are loading.
  bool get loading => _loading;
  bool _loading = false;

  /// Whether purchases can be made now: signed in, the API verifies this
  /// store, and the store answered.
  bool get available => _available;
  bool _available = false;

  /// Whether a purchase or restore is under way.
  bool get busy => _busy;
  bool _busy = false;

  /// The last thing that happened, for the user; null for nothing.
  StoreMessage? get message => _message;
  StoreMessage? _message;

  /// The subscription the store says this account has (verified), if any:
  /// for Manage subscription.
  String? get owned => _owned;
  String? _owned;

  /// Where to manage the subscription.
  Uri get manageUrl => StoreProducts.manage(channel, productId: _owned);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onAuth() {
    final email = auth.user?.email;
    if (email == _for) return;
    _for = email;
    _status = null;
    _plans = const [];
    _available = false;
    _owned = null;
    _message = null;
    _notify();
    if (email != null) load();
  }

  /// Asks the payments API and the store again, then re-verifies the
  /// current subscriptions quietly.
  Future<void> load() async {
    final email = _for;
    final token = auth.idToken;
    if (email == null || token == null) return;
    _loading = true;
    _notify();
    try {
      final status = await client.status(token);
      if (_for != email) return;
      _status = status;
      if (!status.enabled(channel) || !await _store.isAvailable()) return;
      final response = await _store.queryProductDetails(StoreProducts.all);
      final eligible = <String>{};
      if (channel == PurchaseChannel.appStore) {
        for (final id in StoreProducts.all) {
          if (await _trialEligible(id)) eligible.add(id);
        }
      }
      if (_for != email) return;
      _plans = StorePlan.fromDetails(
        response.productDetails,
        trialEligible: eligible,
      );
      _available = _plans.isNotEmpty;
    } catch (e) {
      debugPrint('Presence: the store plans did not load: $e');
    } finally {
      if (_for == email) {
        _loading = false;
        _notify();
      }
    }
    if (_for == email && _status?.enabled(channel) == true) {
      await _restore(quiet: true);
    }
  }

  /// Buys [plan] in the store, for this account.
  Future<void> buy(StorePlan plan) async {
    final token = _status?.accountToken;
    if (!_available || token == null || _busy) return;
    _busy = true;
    _message = null;
    _notify();
    try {
      await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(
          productDetails: plan.details,
          applicationUserName: token,
        ),
      );
    } catch (e) {
      debugPrint('Presence: the purchase did not start: $e');
      _busy = false;
      _message = StoreMessage.purchaseFailed;
      _notify();
    }
  }

  /// Join free (the sign-up sheet): asks the payments API to give the
  /// signed-in account the free membership. The caller checks the roles
  /// again after. Throws [StoreVerifyException] when it didn't.
  Future<void> joinFree() async {
    final token = auth.idToken;
    if (token == null) throw const StoreVerifyException(401);
    await client.joinFree(token);
  }

  /// Restore purchases: verifies the store's current subscriptions again.
  Future<void> restore() => _restore(quiet: false);

  final Set<Future<void>> _inflight = {};
  int _verified = 0;
  bool _quiet = true;

  Future<void> _restore({required bool quiet}) async {
    if (_status?.enabled(channel) != true || auth.idToken == null) return;
    if (!quiet) {
      if (_busy) return;
      _busy = true;
      _message = null;
      _notify();
    }
    _quiet = quiet;
    final before = _verified;
    try {
      await _store.restorePurchases(applicationUserName: _status?.accountToken);
      // The restored purchases arrive on the stream: wait for their checks.
      await Future<void>.delayed(Duration.zero);
      while (_inflight.isNotEmpty) {
        await Future.wait(_inflight.toList());
      }
      if (!quiet && _verified == before) {
        _message ??= StoreMessage.nothingToRestore;
      }
    } catch (e) {
      debugPrint('Presence: restoring purchases failed: $e');
      if (!quiet) _message = StoreMessage.failed;
    } finally {
      _quiet = true;
      if (!quiet) _busy = false;
      _notify();
    }
  }

  void _onPurchases(List<PurchaseDetails> purchases) {
    for (final purchase in purchases) {
      late final Future<void> handled;
      handled = _handle(purchase).whenComplete(() => _inflight.remove(handled));
      _inflight.add(handled);
    }
  }

  Future<void> _handle(PurchaseDetails purchase) async {
    if (!StoreProducts.all.contains(purchase.productID)) return;
    switch (purchase.status) {
      case PurchaseStatus.pending:
        _message = StoreMessage.pending;
        _notify();
      case PurchaseStatus.canceled:
        _busy = false;
        _notify();
      case PurchaseStatus.error:
        _busy = false;
        _message = StoreMessage.purchaseFailed;
        _notify();
        // A failed purchase gives nothing to verify; finish it so it
        // doesn't come back.
        await _complete(purchase);
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        await _verify(purchase);
    }
  }

  Future<void> _verify(PurchaseDetails purchase) async {
    final token = auth.idToken;
    // Signed out: left unfinished, so it comes back after sign-in.
    if (token == null) return;
    final restoring = purchase.status == PurchaseStatus.restored;
    final quiet = restoring && _quiet;
    try {
      await client.verify(
        token,
        platform: channel.platform,
        productId: purchase.productID,
        verificationData: purchase.verificationData.serverVerificationData,
      );
      // Verified and granted: only now is it finished (acknowledged).
      await _complete(purchase);
      _verified++;
      _owned = purchase.productID;
      if (!quiet) {
        _message = restoring ? StoreMessage.restored : StoreMessage.purchased;
      }
      await onVerified?.call();
    } on StoreVerifyException catch (e) {
      debugPrint('Presence: the payments API refused a purchase: ${e.status}');
      if (!quiet) {
        _message = switch (e.status) {
          409 => StoreMessage.otherAccount,
          400 => StoreMessage.notVerified,
          _ => StoreMessage.failed,
        };
      }
    } catch (e) {
      debugPrint('Presence: verifying a purchase failed: $e');
      if (!quiet) _message = StoreMessage.failed;
    } finally {
      if (!restoring) _busy = false;
      _notify();
    }
  }

  Future<void> _complete(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    // StoreKit 2 finishes by transaction ID; without one there's nothing.
    if (channel == PurchaseChannel.appStore && purchase.purchaseID == null) {
      return;
    }
    try {
      await _store.completePurchase(purchase);
    } catch (e) {
      debugPrint('Presence: completing a purchase failed: $e');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _purchases?.cancel();
    _recheck?.cancel();
    if (channel.isStore) auth.removeListener(_onAuth);
    super.dispose();
  }
}
