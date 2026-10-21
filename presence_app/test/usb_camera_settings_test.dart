import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/config.dart';
import 'package:presence_app/l10n/gen/app_localizations.dart';
import 'package:presence_app/usb_camera_settings.dart';

void main() {
  late List<(String, String, Map<String, Object?>)> sent;
  late Map<String, Object?>? status;
  late bool sendWorks;
  late List<(String, String)> reads;
  String? leader;

  Future<void> show(
    WidgetTester tester, {
    List<String> streamers = const ['calm_quiet_otter'],
    ConfigController? config,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: UsbCameraSettings(
              streamers: () => streamers,
              putFile: (device, name, json) async {
                if (!sendWorks) return false;
                sent.add((device, name, json));
                return true;
              },
              getFile: (device, name) async {
                reads.add((device, name));
                return status;
              },
              leader: () => leader,
              config: config,
              poll: const Duration(hours: 1),
              now: () => DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const gopro = {
    'model': 'GoPro HERO6 Black',
    'serial': 'C3221324700631',
    'port': 'usb:001,004',
  };

  setUp(() {
    sent = [];
    status = null;
    sendWorks = true;
    reads = [];
    leader = null;
  });

  testWidgets('without a Linux streamer, it says to set one up', (
    tester,
  ) async {
    await show(tester, streamers: const []);
    expect(find.byKey(const Key('usbcam-no-streamer')), findsOneWidget);
  });

  testWidgets('nothing plugged in: it says so', (tester) async {
    await show(tester);
    expect(reads.single, ('calm_quiet_otter', 'usbcam-status.json'));
    expect(find.text('No USB cameras added yet.'), findsOneWidget);
    expect(find.textContaining('No other camera plugged'), findsOneWidget);
  });

  testWidgets('a camera plugged in is added by its serial, with the name '
      'typed (its model at first); then listed, and removed', (tester) async {
    status = {
      'state': 'ok',
      'detected': [gopro],
    };
    await show(tester);
    expect(find.text('Plugged into it, to add:'), findsOneWidget);
    expect(find.textContaining('C3221324700631'), findsOneWidget);
    final name = find.byKey(const Key('usbcam-name-C3221324700631'));
    expect(
      tester.widget<TextField>(name).controller!.text,
      'GoPro HERO6 Black',
    );
    await tester.enterText(name, 'Helmet');
    await tester.tap(find.byKey(const Key('usbcam-add-C3221324700631')));
    await tester.pumpAndSettle();
    expect(sent.single.$1, 'calm_quiet_otter');
    expect(sent.single.$2, 'usbcam.json');
    expect(sent.single.$3, {
      'add': {'name': 'Helmet', 'serial': 'C3221324700631', 'unattended': true},
      'requestedAt': 1000,
    });
    expect(find.textContaining('Sent to calm_quiet_otter'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('usbcam-add-C3221324700631')),
          )
          .onPressed,
      isNull,
    );

    // The streamer answers: it's added, so no longer offered.
    status = {
      'state': 'ok',
      'requestedAt': 1000,
      'detected': [gopro],
      'cameras': [
        {
          'name': 'Helmet',
          'model': 'GoPro HERO6 Black',
          'serial': 'C3221324700631',
          'deviceId': 'bold_red_fox',
          'plugged': true,
          'lastFetch': 1000,
        },
      ],
    };
    await tester.pumpWidget(Container());
    await show(tester);
    expect(find.text('Its USB cameras:'), findsOneWidget);
    expect(find.byKey(const Key('usbcam-camera-bold_red_fox')), findsOneWidget);
    expect(find.text('GoPro HERO6 Black · C3221324700631'), findsOneWidget);
    expect(find.textContaining('Videos last fetched'), findsOneWidget);
    expect(find.byKey(const Key('usbcam-add-C3221324700631')), findsNothing);

    await tester.tap(find.byKey(const Key('usbcam-remove-bold_red_fox')));
    await tester.pumpAndSettle();
    expect(sent.last.$3, {'remove': 'bold_red_fox', 'requestedAt': 1000});
  });

  testWidgets("unplugged, a camera's error, and the streamer's error show", (
    tester,
  ) async {
    status = {
      'state': 'error',
      'error': "gphoto2 isn't installed (sudo apt install gphoto2)",
      'cameras': [
        {
          'name': 'Helmet',
          'serial': 'C3221324700631',
          'deviceId': 'bold_red_fox',
          'plugged': false,
        },
        {
          'name': 'Canon',
          'model': 'Canon EOS 600D',
          'serial': '0123abc',
          'deviceId': 'calm_blue_owl',
          'plugged': true,
          'error':
              "the camera is busy: another program (the desktop's file "
              'manager) has it open',
        },
      ],
    };
    await show(tester);
    expect(find.textContaining("USB cameras: gphoto2 isn't"), findsOneWidget);
    expect(find.textContaining('Not plugged in'), findsOneWidget);
    expect(
      find.textContaining("Can't fetch: the camera is busy"),
      findsOneWidget,
    );
  });

  testWidgets('unattended is on by default on the add form, and can be '
      'turned off before adding', (tester) async {
    status = {
      'state': 'ok',
      'detected': [gopro],
    };
    await show(tester);
    final unattended = find.byKey(
      const Key('usbcam-unattended-C3221324700631'),
    );
    expect(tester.widget<SwitchListTile>(unattended).value, isTrue);
    expect(
      find.text(
        'Unattended: keep only the parts with movement and delete videos '
        'from the camera once fetched',
      ),
      findsOneWidget,
    );
    await tester.tap(unattended);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(unattended).value, isFalse);
    await tester.tap(find.byKey(const Key('usbcam-add-C3221324700631')));
    await tester.pumpAndSettle();
    expect(sent.single.$3, {
      'add': {
        'name': 'GoPro HERO6 Black',
        'serial': 'C3221324700631',
        'unattended': false,
      },
      'requestedAt': 1000,
    });
  });

  testWidgets("each camera's switch shows its mode and sends a set request", (
    tester,
  ) async {
    status = {
      'state': 'ok',
      'cameras': [
        {
          'name': 'Porch',
          'serial': 'C3221324700631',
          'deviceId': 'bold_red_fox',
          'unattended': true,
          'plugged': true,
        },
        {
          'name': 'Older streamer',
          'serial': '0123abc',
          'deviceId': 'calm_blue_owl',
          'plugged': true,
        },
      ],
    };
    await show(tester);
    final porch = find.byKey(const Key('usbcam-unattended-bold_red_fox'));
    expect(tester.widget<SwitchListTile>(porch).value, isTrue);
    // A streamer that doesn't say has no such mode.
    expect(
      find.byKey(const Key('usbcam-unattended-calm_blue_owl')),
      findsNothing,
    );
    await tester.tap(porch);
    await tester.pumpAndSettle();
    expect(sent.single.$1, 'calm_quiet_otter');
    expect(sent.single.$2, 'usbcam.json');
    expect(sent.single.$3, {
      'set': {'deviceId': 'bold_red_fox', 'unattended': false},
      'requestedAt': 1000,
    });
    // Shown as sent till the streamer answers, the switch waiting.
    expect(tester.widget<SwitchListTile>(porch).value, isFalse);
    expect(tester.widget<SwitchListTile>(porch).onChanged, isNull);
    expect(find.textContaining('Sent to calm_quiet_otter'), findsOneWidget);
  });

  testWidgets('a send that fails says so', (tester) async {
    status = {
      'state': 'ok',
      'detected': [gopro],
    };
    sendWorks = false;
    await show(tester);
    await tester.tap(find.byKey(const Key('usbcam-add-C3221324700631')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't send it"), findsOneWidget);
  });

  testWidgets('the streamer picked is kept for USB cameras only', (
    tester,
  ) async {
    final config = ConfigController();
    leader = 'calm_quiet_otter';
    await show(
      tester,
      streamers: ['calm_quiet_otter', 'brave_little_lamp'],
      config: config,
    );
    expect(reads.last.$1, 'calm_quiet_otter');
    await tester.tap(find.byKey(const Key('usbcam-streamer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('brave_little_lamp').last);
    await tester.pumpAndSettle();
    expect(config.integrations.streamerFor('usbcam'), 'brave_little_lamp');
    expect(config.integrations.streamerFor('gopro'), isNull);
    expect(reads.last.$1, 'brave_little_lamp');
  });

  testWidgets('fits 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    status = {
      'state': 'ok',
      'detected': [
        gopro,
        {
          'model': 'Canon EOS 600D with a long name',
          'serial': '0123456789abcdef0123',
          'port': 'usb:001,005',
        },
      ],
      'cameras': [
        {
          'name': 'A camera with a rather long name',
          'model': 'GoPro HERO7 Black',
          'serial': 'C3221324700632',
          'deviceId': 'automatic_paranoid_gadget',
          'unattended': true,
          'plugged': true,
          'lastFetch': 1000,
        },
      ],
    };
    await show(tester);
    expect(tester.takeException(), isNull);
  });
}
