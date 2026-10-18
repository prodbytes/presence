import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/gopro_settings.dart';
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
            child: GoProSettings(
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
    expect(find.byKey(const Key('gopro-no-streamer')), findsOneWidget);
  });

  testWidgets('add: the camera goes to the streamer, sealed; then it lists '
      'it, and removes it', (tester) async {
    await show(tester);
    expect(find.text('No GoPro cameras yet.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('gopro-name')), 'Helmet');
    await tester.enterText(
      find.byKey(const Key('gopro-address')),
      '192.168.1.50',
    );
    await tester.enterText(find.byKey(const Key('gopro-password')), 'pw');
    await tester.ensureVisible(find.byKey(const Key('gopro-add')));
    await tester.tap(find.byKey(const Key('gopro-add')));
    await tester.pumpAndSettle();
    expect(sent.single.$1, 'calm_quiet_otter');
    expect(sent.single.$2, 'gopro.json');
    expect(sent.single.$3, {
      'add': {'name': 'Helmet', 'address': '192.168.1.50', 'password': 'pw'},
      'requestedAt': 1000,
    });
    expect(find.textContaining('Sent to calm_quiet_otter'), findsOneWidget);
    // The form is cleared, and waits for the answer.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('gopro-password')))
          .controller!
          .text,
      '',
    );
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('gopro-add'))).onPressed,
      isNull,
    );

    // The streamer answers with the camera.
    status = {
      'state': 'ok',
      'requestedAt': 1000,
      'cameras': [
        {
          'name': 'Helmet',
          'deviceId': 'bold_red_fox',
          'address': 'https://192.168.1.50',
          'lastFetch': 1000,
        },
      ],
    };
    await tester.pumpWidget(Container());
    await show(tester);
    expect(find.text('Its GoPro cameras:'), findsOneWidget);
    expect(find.byKey(const Key('gopro-camera-bold_red_fox')), findsOneWidget);
    expect(find.text('https://192.168.1.50'), findsOneWidget);
    expect(find.textContaining('Videos last fetched'), findsOneWidget);

    await tester.tap(find.byKey(const Key('gopro-remove-bold_red_fox')));
    await tester.pumpAndSettle();
    expect(sent.last.$3, {'remove': 'bold_red_fox', 'requestedAt': 1000});
  });

  testWidgets("an error shows, and a camera's own", (tester) async {
    status = {
      'state': 'error',
      'error': 'the camera refused the password',
      'requestedAt': 5,
      'cameras': [
        {
          'name': 'Dash',
          'deviceId': 'bold_red_fox',
          'address': 'http://10.5.5.9:8080',
          'error': 'connection refused',
        },
      ],
    };
    await show(tester);
    expect(find.text('GoPro: the camera refused the password'), findsOneWidget);
    expect(find.text("Can't fetch: connection refused"), findsOneWidget);
    expect(find.byKey(const Key('gopro-add')), findsOneWidget);
  });

  testWidgets('a send that fails says so', (tester) async {
    sendWorks = false;
    await show(tester);
    await tester.enterText(
      find.byKey(const Key('gopro-address')),
      '172.24.106.51',
    );
    await tester.ensureVisible(find.byKey(const Key('gopro-add')));
    await tester.tap(find.byKey(const Key('gopro-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't send it"), findsOneWidget);
    // Kept, to try again.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('gopro-address')))
          .controller!
          .text,
      '172.24.106.51',
    );
  });
}
