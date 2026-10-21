import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/streamer_command.dart';
import 'package:presence_app/identity/device_id.dart';

import 'fakes.dart';

void main() {
  const key = 'psk_0123456789abcdefghijABCDEFGHIJ_-01234567890';

  test('the command installs the streamer as the device, with its key', () {
    expect(
      streamerCommand('automatic_paranoid_axolotl', 'calm_quiet_otter', key),
      'curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- '
      '--profile automatic_paranoid_axolotl --device-id calm_quiet_otter '
      '--key $key',
    );
    // Nothing that would need quoting in a shell.
    expect(streamerCommand('a_b_c; rm -rf /', 'calm_quiet_otter', key), isNull);
    expect(streamerCommand(r'$(id)_b_c', 'calm_quiet_otter', key), isNull);
    expect(streamerCommand('a_b_c', 'calm_quiet_otter', 'psk_x;id'), isNull);
    expect(streamerCommand('a_b_c', '', key), isNull);
  });

  testWidgets('creates a device and its key, then copies the command', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    final profiles = FakeProfileClient();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamerCommand(
            profileId: 'automatic_paranoid_axolotl',
            auth: FakeAuthService.signedIn(),
            profiles: profiles,
          ),
        ),
      ),
    );

    expect(find.text('Streamer'), findsOneWidget);
    // No key until asked: each command is a new device.
    expect(find.byKey(const Key('streamer-command-text')), findsNothing);
    expect(profiles.streamKeys, isEmpty);
    await tester.tap(find.byKey(const Key('streamer-command-create')));
    await tester.pumpAndSettle();

    final device = profiles.streamKeys.keys.single;
    expect(DeviceId.pattern.hasMatch(device), isTrue);
    final command =
        'curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- '
        '--profile automatic_paranoid_axolotl --device-id $device '
        '--key ${profiles.streamKeys[device]}';
    expect(find.text(command), findsOneWidget);
    expect(find.byKey(const Key('streamer-command-once')), findsOneWidget);
    await tester.tap(find.byKey(const Key('streamer-command-copy')));
    await tester.pump();
    expect(copied, command);
    expect(
      find.text('Command copied: paste it on the streamer'),
      findsOneWidget,
    );
  });

  testWidgets('says why it couldn\'t create one', (tester) async {
    final profiles = FakeProfileClient()..error = Exception('HTTP 503');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamerCommand(
            profileId: 'automatic_paranoid_axolotl',
            auth: FakeAuthService.signedIn(),
            profiles: profiles,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('streamer-command-create')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('streamer-command-error')), findsOneWidget);
    expect(find.byKey(const Key('streamer-command-text')), findsNothing);
  });

  testWidgets('shows nothing for an ID that isn\'t a profile\'s', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StreamerCommand(
            profileId: 'not a profile',
            auth: FakeAuthService.signedIn(),
            profiles: FakeProfileClient(),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('streamer-command')), findsNothing);
  });
}
