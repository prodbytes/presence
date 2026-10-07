import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/identity/device_id.dart';
import 'package:presence_app/identity/join_link.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/settings.dart';

import 'fakes.dart';

void main() {
  final app = Uri.parse('https://presence.test/app/');

  group('the join link', () {
    test('carries the device and a code for the user, not their ID', () {
      final link = JoinLink.build(
        from: 'automatic_paranoid_gadget',
        userId: '1234567890',
        app: app,
      );
      expect(link.origin, 'https://presence.test');
      expect(link.path, '/app/');
      expect(link.queryParameters, {
        'from': 'automatic_paranoid_gadget',
        'user': JoinLink.userCode('1234567890'),
      });
      expect('$link', isNot(contains('1234567890')));
      expect(
        JoinLink.userCode('1234567890'),
        matches(RegExp(r'^[0-9a-f]{16}$')),
      );
      expect(
        JoinLink.userCode('1234567890'),
        isNot(JoinLink.userCode('1234567891')),
      );
    });

    test('reads back; other links are not join links', () {
      final link = JoinLink.parse(
        JoinLink.build(from: 'a_b_c', userId: '1', app: app),
      )!;
      expect(link.from, 'a_b_c');
      expect(link.isFor('1'), isTrue);
      expect(link.isFor('2'), isFalse);
      expect(link.isFor(null), isFalse);
      // Without a user (DEV), anyone.
      final anyone = JoinLink.parse(JoinLink.build(from: 'a_b_c', app: app))!;
      expect(anyone.user, isNull);
      expect(anyone.isFor(null), isTrue);
      expect(JoinLink.parse(app), isNull);
      expect(
        JoinLink.parse(Uri.parse('https://presence.test/app/?x=1')),
        isNull,
      );
    });

    test('says where a device opened with it stands', () {
      final link = JoinLink(from: 'a_b_c', user: JoinLink.userCode('1'));
      JoinStatus of({
        String? deviceId = 'd_e_f',
        String? userId,
        bool checking = false,
        bool dev = false,
      }) => JoinStatus.of(
        link,
        deviceId: deviceId,
        userId: userId,
        checking: checking,
        dev: dev,
      );
      expect(of(deviceId: null), JoinStatus.waiting);
      expect(of(deviceId: 'a_b_c', userId: '1'), JoinStatus.sameDevice);
      expect(of(checking: true), JoinStatus.waiting);
      expect(of(), JoinStatus.signIn);
      expect(of(userId: '1'), JoinStatus.joined);
      expect(of(userId: '2'), JoinStatus.otherUser);
      expect(of(dev: true), JoinStatus.joined);
    });
  });

  group('the app', () {
    late IdbFactory storage;
    setUp(() => storage = newIdbFactoryMemory());

    Future<void> launch(
      WidgetTester tester, {
      AuthService? auth,
      Stream<Uri>? links,
      FakeRolesClient? roles,
    }) async {
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          key: UniqueKey(),
          cameras: noCameras,
          storage: storage,
          auth: auth ?? FakeAuthService.signedIn(),
          rolesClient: roles ?? FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
          links: links ?? const Stream.empty(),
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);
      await tester.pumpAndSettle();
    }

    /// Scrolls to "Add a device", last in Settings, and returns its link.
    Future<Uri> openAddDevice(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      // Shown in place, no dialog.
      await scrollSettingsTo(tester, find.byKey(const Key('add-device-share')));
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('add-device-qr')),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
      expect(
        tester.widget<QrImageView>(find.byKey(const Key('add-device-qr'))).size,
        200,
      );
      expect(find.byKey(const Key('add-device-share')), findsOneWidget);
      expect(find.byKey(const Key('add-device-copy')), findsOneWidget);
      return Uri.parse(
        tester
            .widget<SelectableText>(find.byKey(const Key('add-device-link')))
            .data!,
      );
    }

    String deviceIdShown(WidgetTester tester) => tester
        .widget<SelectableText>(
          find.byKey(const Key('device-id'), skipOffstage: false),
        )
        .data!;

    testWidgets('Settings always shows the device and profile IDs', (
      tester,
    ) async {
      final roles = FakeRolesClient();
      await launch(tester, roles: roles);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await scrollSettingsTo(tester, find.byKey(const Key('profile-id')));
      expect(deviceIdShown(tester), matches(DeviceId.pattern));
      expect(find.text('Device'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byKey(const Key('profile-id'))).data,
        'automatic_paranoid_axolotl',
      );
      // Side by side at the top: the device ID left, the profile ID right.
      expect(
        tester.getTopLeft(find.byKey(const Key('profile-id'))).dy,
        tester.getTopLeft(find.byKey(const Key('device-id'))).dy,
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('profile-id'))).dx,
        greaterThan(tester.getTopRight(find.byKey(const Key('device-id'))).dx),
      );
    });

    testWidgets('signed out, without an answer or in DEV, Settings shows '
        'no profile', (tester) async {
      String profileShown() =>
          tester.widget<Text>(find.byKey(const Key('profile-id'))).data!;
      Future<void> openSettings() async {
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        await scrollSettingsTo(tester, find.byKey(const Key('profile-id')));
      }

      await launch(tester, roles: FakeRolesClient()..profile = null);
      await openSettings();
      expect(profileShown(), 'none until signed in');

      final dev = FakeRolesClient()..mode = ExecutionMode.dev;
      await launch(tester, auth: FakeAuthService(), roles: dev);
      await openSettings();
      expect(profileShown(), 'none until signed in');
      expect(deviceIdShown(tester), matches(DeviceId.pattern));
    });

    testWidgets('before the IDs load, Settings says so', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsView(config: ConfigController())),
        ),
      );
      await scrollSettingsTo(tester, find.byKey(const Key('profile-id')));
      expect(find.text('loading…'), findsOneWidget);
      expect(find.text('none until signed in'), findsOneWidget);
    });

    testWidgets('Settings ends with a QR code for this device and user', (
      tester,
    ) async {
      await launch(tester);
      // The ID at the top of Settings, then the link at the bottom.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final deviceId = deviceIdShown(tester);
      expect(deviceId, matches(DeviceId.pattern));
      final link = await openAddDevice(tester);
      expect(
        JoinLink.parse(link),
        JoinLink(from: deviceId, user: JoinLink.userCode('1')),
      );
      expect(find.textContaining('ana@example.com'), findsOneWidget);
      // It's the last thing: below the health line.
      expect(
        tester.getTopLeft(find.byKey(const Key('add-device'))).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const Key('system-health'))).dy,
        ),
      );
    });

    testWidgets('in DEV, the link has no user', (tester) async {
      await launch(
        tester,
        auth: FakeAuthService(),
        roles: FakeRolesClient()..mode = ExecutionMode.dev,
      );
      final link = await openAddDevice(tester);
      expect(link.queryParameters.keys, ['from']);
    });

    testWidgets(
      'opened with a link signed out, it asks to sign in; the same user joins',
      (tester) async {
        final links = StreamController<Uri>();
        addTearDown(links.close);
        final auth = FakeAuthService();
        await launch(tester, auth: auth, links: links.stream);
        links.add(
          JoinLink.build(from: 'other_device_here', userId: '1', app: app),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('join-banner')), findsOneWidget);
        expect(
          find.textContaining('sign in with the Google account'),
          findsOneWidget,
        );

        await auth.signIn();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('join-banner')), findsNothing);
        expect(
          find.textContaining("now one of ana@example.com's"),
          findsOneWidget,
        );
        // As a new device: its own ID, not the one that shared the link.
        await tester.pump(const Duration(seconds: 5)); // the message goes
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        expect(deviceIdShown(tester), isNot('other_device_here'));
      },
    );

    testWidgets('another user is told so, and can sign out', (tester) async {
      final auth = FakeAuthService.signedIn();
      await launch(
        tester,
        auth: auth,
        links: Stream.value(
          JoinLink.build(from: 'other_device_here', userId: '2', app: app),
        ),
      );
      expect(find.textContaining('another Google account'), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(auth.user, isNull);
      // Still to do: sign in as the right one.
      expect(
        find.textContaining('sign in with the Google account'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('join-banner')), findsNothing);
    });

    testWidgets('the device that shared the link says to use another', (
      tester,
    ) async {
      await launch(tester);
      final link = await openAddDevice(tester);
      // Opened again on the same device (a reload with the link).
      await launch(tester, links: Stream.value(link));
      expect(
        find.textContaining('This is the device that shared'),
        findsOneWidget,
      );
    });
  });
}
