import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/status_pill.dart';
import 'package:presence_app/system_health.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget pill) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: pill)),
    ),
  );

  /// The semantics of the one node labeled [label].
  SemanticsData labeled(String label) =>
      find.semantics.byLabel(label).evaluate().single.getSemanticsData();

  testWidgets('a pill is not a live region by default: a countdown or the '
      'battery is not read out on every change', (tester) async {
    final handle = tester.ensureSemantics();
    await show(
      tester,
      const StatusPill(
        key: Key('pill'),
        leading: Icon(Icons.circle),
        label: '4:59',
        semantics: 'Next automatic clip in 4:59',
      ),
    );
    final data = labeled('Next automatic clip in 4:59');
    expect(data.flagsCollection.isLiveRegion, isFalse);
    expect(data.flagsCollection.isButton, isFalse);
    handle.dispose();
  });

  testWidgets('a camera message is a live region, and a button when it '
      'opens its event', (tester) async {
    final handle = tester.ensureSemantics();
    var opened = 0;
    await show(
      tester,
      CameraMessagePill(
        message: const CameraMessage(icon: Icons.camera, label: 'Clip started'),
        onView: () => opened++,
      ),
    );
    final key = const Key('camera-message');
    final data = labeled('Clip started. Tap to view it.');
    expect(data.flagsCollection.isLiveRegion, isTrue);
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);

    await tester.tap(find.byKey(key));
    expect(opened, 1);
    // A screen reader's double tap opens it too.
    tester.semantics.tap(
      find.semantics.byLabel('Clip started. Tap to view it.'),
    );
    expect(opened, 2);

    // Nothing to open: only news.
    await show(
      tester,
      const CameraMessagePill(
        message: CameraMessage(icon: Icons.error, label: 'Sign-in failed'),
      ),
    );
    final quiet = labeled('Sign-in failed');
    expect(quiet.flagsCollection.isLiveRegion, isTrue);
    expect(quiet.flagsCollection.isButton, isFalse);
    handle.dispose();
  });

  testWidgets('the health warning is a live region and a button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var tapped = 0;
    await show(
      tester,
      HealthWarningPill(
        failed: const ['Auth API: no answer'],
        onTap: () => tapped++,
      ),
    );
    final data = labeled(
      'Health check failed\nAuth API: no answer\nTap for details.',
    );
    expect(data.flagsCollection.isLiveRegion, isTrue);
    expect(data.flagsCollection.isButton, isTrue);
    await tester.tap(find.byKey(const Key('health-warning')));
    expect(tapped, 1);
    handle.dispose();
  });
}
