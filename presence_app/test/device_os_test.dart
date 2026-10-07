import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/events.dart';
import 'package:presence_app/identity/device_os.dart';

void main() {
  group('AppEvent.os', () {
    test('round-trips through the stored record', () {
      final event = AppEvent(
        icon: Icons.circle,
        title: 'Door opened',
        time: DateTime(2026, 10, 6, 12),
        deviceId: 'brave_quiet_lamp',
      )..os = 'Android';
      final record = event.toRecord();
      expect(record['os'], 'Android');
      expect(AppEvent.fromRecord(record)!.os, 'Android');
    });

    test('older records without one restore with none, and save without '
        'one', () {
      final event = AppEvent(
        icon: Icons.circle,
        title: 'Door opened',
        time: DateTime(2026, 10, 6, 12),
      );
      final record = event.toRecord();
      expect(record.containsKey('os'), isFalse);
      final restored = AppEvent.fromRecord(record)!;
      expect(restored.os, isNull);
      expect(AppEvent.osOf({'os': ''}), isNull);
      expect(AppEvent.osOf({'os': 3}), isNull);
    });
  });

  group('DeviceOs', () {
    test('names this platform', () {
      expect(DeviceOs.current, isNotEmpty);
      expect(DeviceOs.ofPlatform('android'), 'Android');
      expect(DeviceOs.ofPlatform('ios'), 'iOS');
      expect(DeviceOs.ofPlatform('macos'), 'macOS');
      expect(DeviceOs.ofPlatform('windows'), 'Windows');
      expect(DeviceOs.ofPlatform('linux'), 'Linux');
    });

    test('names the browser and its system from the user agent', () {
      expect(
        DeviceOs.ofUserAgent(
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36',
        ),
        'Web (Chrome, macOS)',
      );
      expect(
        DeviceOs.ofUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0',
        ),
        'Web (Edge, Windows)',
      );
      expect(
        DeviceOs.ofUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1',
        ),
        'Web (Safari, iOS)',
      );
      expect(
        DeviceOs.ofUserAgent(
          'Mozilla/5.0 (Android 14; Mobile; rv:131.0) Gecko/131.0 '
          'Firefox/131.0',
        ),
        'Web (Firefox, Android)',
      );
      expect(DeviceOs.ofUserAgent('curl/8.0'), 'Web');
    });

    test('names browsers on iOS by their own token, not as Safari', () {
      const webkit =
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1';
      const iphone = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) ';
      expect(
        DeviceOs.ofUserAgent('$iphone$webkit EdgiOS/129.0.2792.84'),
        'Web (Edge, iOS)',
      );
      expect(
        DeviceOs.ofUserAgent('$iphone$webkit OPT/5.0.5'),
        'Web (Opera, iOS)',
      );
      expect(
        DeviceOs.ofUserAgent('$iphone$webkit FxiOS/131.0'),
        'Web (Firefox, iOS)',
      );
      expect(
        DeviceOs.ofUserAgent('$iphone$webkit CriOS/129.0.6668.69'),
        'Web (Chrome, iOS)',
      );
      // Opera and Edge on Android carry Chrome's token too.
      expect(
        DeviceOs.ofUserAgent(
          'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, '
          'like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36 OPR/85.0.0',
        ),
        'Web (Opera, Android)',
      );
      expect(
        DeviceOs.ofUserAgent(
          'Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, '
          'like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36 EdgA/129.0.0.0',
        ),
        'Web (Edge, Android)',
      );
    });

    test('takes a touch-screen Mac user agent for an iPad', () {
      const mac =
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
          '(KHTML, like Gecko) Version/18.0 Safari/605.1.15';
      expect(DeviceOs.ofUserAgent(mac, maxTouchPoints: 5), 'Web (Safari, iOS)');
      expect(DeviceOs.ofUserAgent(mac), 'Web (Safari, macOS)');
      // A single touch point (some Mac browsers report one) is still a Mac.
      expect(
        DeviceOs.ofUserAgent(mac, maxTouchPoints: 1),
        'Web (Safari, macOS)',
      );
      // Touch points don't make other systems iOS.
      expect(
        DeviceOs.ofUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36',
          maxTouchPoints: 10,
        ),
        'Web (Chrome, Windows)',
      );
    });

    test('has an icon for each system', () {
      expect(DeviceOs.iconOf('Android'), Icons.android);
      expect(DeviceOs.iconOf('iOS'), Icons.phone_iphone);
      expect(DeviceOs.iconOf('macOS'), Icons.laptop_mac);
      expect(DeviceOs.iconOf('Windows'), Icons.desktop_windows);
      expect(DeviceOs.iconOf('Linux'), Icons.computer);
      expect(DeviceOs.iconOf('Web (Chrome, macOS)'), Icons.language);
      expect(DeviceOs.iconOf('Plan 9'), Icons.devices_other);
      expect(DeviceOs.iconOf(null), Icons.devices_other);
    });
  });

  testWidgets("an event's device tag shows its OS, and fits 320 dp", (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final filter = ValueNotifier('');
    addTearDown(filter.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EventDeviceTag(
                key: const Key('with-os'),
                device: 'automatic_paranoid_gadget_extraordinaire',
                thisDevice: true,
                os: 'Web (Firefox, Android)',
                value: filter,
              ),
              EventDeviceTag(
                key: const Key('without-os'),
                device: 'brave_quiet_lamp',
                thisDevice: false,
                value: filter,
              ),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const Key('with-os')),
        matching: find.byIcon(Icons.language),
      ),
      findsOneWidget,
    );
    expect(find.text(' · Web (Firefox, Android)'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('without-os')),
        matching: find.byIcon(Icons.devices_other),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('event-device-os')), findsOneWidget);
  });
}
