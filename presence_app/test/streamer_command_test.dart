import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/streamer_command.dart';

void main() {
  test('the command installs the streamer for the profile', () {
    expect(
      streamerCommand('automatic_paranoid_axolotl'),
      'curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- automatic_paranoid_axolotl',
    );
    // Nothing that would need quoting in a shell.
    expect(streamerCommand('a_b_c; rm -rf /'), isNull);
    expect(streamerCommand(r'$(id)_b_c'), isNull);
    expect(streamerCommand(''), isNull);
  });

  testWidgets('shows the command and copies it', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
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
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StreamerCommand(profileId: 'automatic_paranoid_axolotl'),
        ),
      ),
    );

    expect(find.text('Stream from a Raspberry Pi'), findsOneWidget);
    expect(
      find.text(
        'curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- automatic_paranoid_axolotl',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('streamer-command-copy')));
    await tester.pump();
    expect(
      copied,
      'curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- automatic_paranoid_axolotl',
    );
    expect(
      find.text('Command copied: paste it on the Raspberry Pi'),
      findsOneWidget,
    );
  });

  testWidgets('shows nothing for an ID that isn\'t a profile\'s', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StreamerCommand(profileId: 'not a profile')),
      ),
    );
    expect(find.byKey(const Key('streamer-command')), findsNothing);
  });
}
