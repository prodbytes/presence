/// The App Store screenshots: the real app on an iOS Simulator, signed in
/// as a made-up account (fakes, no network but the map's tiles), with
/// demo events made from the cat photos in `test/data/`. It doesn't take
/// the pictures itself: at each screen it prints `SHOT <name>` and holds
/// still while `scripts/app-store-screenshots.sh` takes it with
/// `xcrun simctl io booted screenshot`.
///
/// ```sh
/// bash scripts/app-store-screenshots.sh   # boots the simulator, runs this
/// ```
///
/// `SHOTS_DATA` (a `--dart-define`) is the absolute path of
/// `presence_app/test/data`: the simulator's apps read the Mac's files.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';
import 'package:integration_test/integration_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/profile_client.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/auth/store_billing.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/crypto/media_seal.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/location/device_location.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';

import '../test/fakes.dart';
import '../test/sealed.dart';
import '../test/store_billing_test.dart'
    show FakeStoreClient, FakeStorePlatform;

const data = String.fromEnvironment('SHOTS_DATA');

/// Golden Gate Park: a public place, not anyone's home.
const here = (latitude: 37.7694, longitude: -122.4862, accuracy: 12.0);

Uint8List photo(String name) =>
    File('$data/cats/suerte/photos/$name').readAsBytesSync();

/// A camera showing a still photo as its live picture.
class PhotoCamera extends FakeCameraSource {
  PhotoCamera(super.label, this.picture);

  final Uint8List picture;

  @override
  Widget buildPreview(BuildContext context) => SizedBox.expand(
    child: Image.memory(picture, fit: BoxFit.cover, gaplessPlayback: true),
  );

  @override
  Future<Uint8List?> captureFrame() async => picture;
}

class HereLocator implements Locator {
  @override
  Future<({double latitude, double longitude, double? accuracy})>
  locate() async => here;
}

/// Holds still for the screenshot named [name].
Future<void> shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  // Map tiles and images arrive in real time.
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  // ignore: avoid_print
  print('SHOT $name');
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
}

/// Saves demo events, as the app would have recorded them, on [storage].
Future<void> seed(IdbFactory storage) async {
  final bus = AppEventBus();
  final persistence = Persistence(
    factory: Future.value(storage),
    bus: bus,
    config: ConfigController(),
    currentUser: () => '1',
    currentProfile: () => 'automatic_paranoid_axolotl',
    currentLocation: () => DeviceLocation(
      latitude: here.latitude,
      longitude: here.longitude,
      accuracy: here.accuracy,
      source: LocationSource.device,
      time: DateTime.now(),
    ),
    mediaStore: (store) => IdbMediaStore(store, fakeMediaIo),
  );
  // This device's key, made with its identity on [storage].
  while (MediaSeal.instance.keys.ownNow == null) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  final now = DateTime.now();
  var n = 0;
  void clip(
    String file,
    Duration ago, {
    ClipTrigger trigger = ClipTrigger.motion,
    String camera = 'Porch',
    List<String> subjects = const [],
    List<String> objects = const [],
  }) {
    n++;
    final media = ClipMedia(
      url: 'demo:$n',
      start: Duration.zero,
      end: const Duration(seconds: 30),
    );
    final annotations = ClipAnnotations();
    for (final s in subjects) {
      annotations.add(s, 0.5, 0.55, source: TagSource.manual);
    }
    annotations.addObjects([
      for (final o in objects) ObjectTag(label: o, ms: 2000, score: 0.9),
    ]);
    bus.publish(
      ClipRequested(
        // Recorded, as a camera would (the recording is a stand-in).
        VideoClip(
          id: 'demo-clip-$n',
          cameraId: 'cam-$camera',
          cameraLabel: camera,
          before: const Duration(seconds: 15),
          after: const Duration(seconds: 15),
          capture: ClipCapture(
            past: Future.value(media),
            full: Future.value(media),
          ),
          // Sealed with this device's key, as the app stores images.
          thumbnail: sealed(photo(file)),
        ),
        trigger: trigger,
        annotations: annotations,
        time: now.subtract(ago),
        id: 'demo-event-$n',
      ),
    );
  }

  clip('IMG_2680.jpg', const Duration(minutes: 4), subjects: ['Suerte']);
  clip(
    'IMG_2534.jpg',
    const Duration(minutes: 47),
    camera: 'Garden',
    subjects: ['Suerte'],
    objects: ['cat'],
  );
  clip(
    'IMG_2677.jpg',
    const Duration(hours: 3, minutes: 12),
    subjects: ['Suerte'],
  );
  clip(
    'IMG_0191.jpg',
    const Duration(hours: 9),
    camera: 'Garden',
    trigger: ClipTrigger.scheduled,
    objects: ['cat'],
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  await persistence.flush();
  await bus.close();
}

/// The App Store's two Premium subscriptions, at their US prices, the
/// monthly one with its one-week free trial.
List<ProductDetails> products() {
  AppStoreProduct2Details product(
    String id,
    String name,
    String price,
    double raw,
    SK2SubscriptionPeriodUnit unit, {
    bool trial = false,
  }) => AppStoreProduct2Details.fromSK2Product(
    SK2Product(
      id: id,
      displayName: name,
      displayPrice: price,
      description: 'Cloud backup and up to 25 devices',
      price: raw,
      type: SK2ProductType.autoRenewable,
      priceLocale: SK2PriceLocale(currencyCode: 'USD', currencySymbol: r'$'),
      subscription: SK2SubscriptionInfo(
        subscriptionGroupID: '22485520',
        subscriptionPeriod: SK2SubscriptionPeriod(value: 1, unit: unit),
        promotionalOffers: [
          if (trial)
            SK2SubscriptionOffer(
              price: 0,
              type: SK2SubscriptionOfferType.introductory,
              period: const SK2SubscriptionPeriod(
                value: 1,
                unit: SK2SubscriptionPeriodUnit.week,
              ),
              periodCount: 1,
              paymentMode: SK2SubscriptionOfferPaymentMode.freeTrial,
            ),
        ],
      ),
    ),
  );
  return [
    product(
      StoreProducts.monthly,
      'Premium Monthly',
      r'$20.00',
      20,
      SK2SubscriptionPeriodUnit.month,
      trial: true,
    ),
    product(
      StoreProducts.yearly,
      'Premium Yearly',
      r'$200.00',
      200,
      SK2SubscriptionPeriodUnit.year,
    ),
  ];
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // The App Store, faked: registered first, so it isn't replaced.
    InAppPurchase.instance;
    InAppPurchasePlatform.instance = FakeStorePlatform(products: products());
    // A new subscriber gets the free trial.
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.in_app_purchase_storekit.InAppPurchase2API'
      '.isIntroductoryOfferEligible',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[true]),
    );
  });

  testWidgets('App Store screenshots', (tester) async {
    expect(data, isNotEmpty, reason: 'pass --dart-define=SHOTS_DATA=...');
    final storage = newIdbFactoryMemory();
    await tester.runAsync(() => seed(storage));

    final camera = PhotoCamera('Porch', photo('IMG_2534.jpg'));
    Widget app({bool consent = true, IdbFactory? store}) => PresenceApp(
      key: UniqueKey(),
      consentGiven: consent,
      cameras: openFakes([camera]),
      storage: store ?? storage,
      mediaIo: fakeMediaIo,
      auth: FakeAuthService(
        account: const AuthUser(
          id: '1',
          email: 'alex@example.com',
          name: 'Alex Rivera',
        ),
        signedIn: true,
      ),
      rolesClient: FakeRolesClient([userRole]),
      rbacrClient: FakeRbacrClient()
        ..answer = (email: 'alex@example.com', root: false, roles: const {}),
      profileClient: FakeProfileClient([
        const ProfileAccount(
          email: 'alex@example.com',
          owner: true,
          current: true,
        ),
      ]),
      storeClient: FakeStoreClient(),
      feedbackClient: FakeFeedbackClient(),
      locator: HereLocator(),
    );

    // The consent screen, as at first launch (taken first, shown last).
    await tester.pumpWidget(app(consent: false, store: newIdbFactoryMemory()));
    await shot(tester, '5-consent');

    // The camera.
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await shot(tester, '1-camera');

    // The events, with the map.
    await tester.tap(find.byTooltip('Events'));
    await shot(tester, '2-events');

    // Setup.
    await tester.tap(find.byTooltip('Setup'));
    await shot(tester, '3-setup');

    // Profile, with the Premium plans.
    await tester.tap(find.byKey(const Key('account-button')));
    await shot(tester, '4-premium');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
  });
}
