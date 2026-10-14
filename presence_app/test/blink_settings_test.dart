import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/blink_settings.dart';
import 'package:presence_app/l10n/gen/app_localizations.dart';

void main() {
  late List<(String, String, Map<String, Object?>)> sent;
  late Map<String, Object?>? status;
  late bool sendWorks;

  Future<void> show(
    WidgetTester tester, {
    List<String> streamers = const ['calm_quiet_otter'],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BlinkSettings(
              streamers: () => streamers,
              putFile: (device, name, json) async {
                if (!sendWorks) return false;
                sent.add((device, name, json));
                return true;
              },
              getFile: (device, name) async => status,
              poll: const Duration(hours: 1),
              now: () => DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    sent = [];
    status = null;
    sendWorks = true;
  });

  testWidgets('without a Linux streamer, it says to set one up', (
    tester,
  ) async {
    await show(tester, streamers: const []);
    expect(find.byKey(const Key('blink-no-streamer')), findsOneWidget);
  });

  testWidgets('connect: the login goes to the streamer, sealed; then the '
      'PIN, without the password; then its cameras, and disconnect', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Not connected to Blink.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blink-email')), 'a@b.c');
    await tester.enterText(find.byKey(const Key('blink-password')), 'secret');
    await tester.tap(find.byKey(const Key('blink-connect')));
    await tester.pumpAndSettle();
    expect(sent.single.$1, 'calm_quiet_otter');
    expect(sent.single.$2, 'blink.json');
    expect(sent.single.$3, {
      'email': 'a@b.c',
      'password': 'secret',
      'requestedAt': 1000,
    });
    expect(find.textContaining('Sent to calm_quiet_otter'), findsOneWidget);

    // Blink asks for a PIN.
    status = {'state': 'pin-required', 'account': 'a@b.c', 'requestedAt': 1000};
    await tester.pumpWidget(Container());
    await show(tester);
    // (A new screen: nothing sent from it yet, so the status shows.)
    expect(find.textContaining("Blink sent a PIN to a@b.c"), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blink-pin')), '123456');
    await tester.tap(find.byKey(const Key('blink-send-pin')));
    await tester.pumpAndSettle();
    expect(sent.last.$3, {
      'email': 'a@b.c',
      'pin': '123456',
      'requestedAt': 1000,
    });
    expect(sent.last.$3.containsKey('password'), isFalse);

    // Connected: its cameras, each a device.
    status = {
      'state': 'connected',
      'account': 'a@b.c',
      'requestedAt': 1000,
      'cameras': [
        {'name': 'Porch', 'deviceId': 'brave_little_lamp'},
      ],
      'lastFetch': 2000,
    };
    await tester.pumpWidget(Container());
    await show(tester);
    expect(find.textContaining('Connected to Blink as a@b.c'), findsOneWidget);
    expect(
      find.byKey(const Key('blink-camera-brave_little_lamp')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('blink-email')), findsNothing);
    await tester.tap(find.byKey(const Key('blink-disconnect')));
    await tester.pumpAndSettle();
    expect(sent.last.$3, {'disconnect': true, 'requestedAt': 1000});
  });

  testWidgets('an error shows, with the login form again; a send that fails '
      'says so', (tester) async {
    status = {'state': 'error', 'error': 'bad password', 'requestedAt': 1};
    sendWorks = false;
    await show(tester);
    expect(find.text('Blink: bad password'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blink-email')), 'a@b.c');
    await tester.enterText(find.byKey(const Key('blink-password')), 'x');
    await tester.tap(find.byKey(const Key('blink-connect')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't send it"), findsOneWidget);
  });
}
