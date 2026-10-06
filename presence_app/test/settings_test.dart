import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/settings.dart';

void main() {
  late ConfigController config;
  setUp(() => config = ConfigController());

  /// The Settings screen alone, [width] wide; with the Log switch (as an
  /// admin sees it) when [logTabDefault] is set.
  Future<void> show(
    WidgetTester tester, {
    double width = 320,
    bool? logTabDefault = false,
  }) async {
    tester.view.physicalSize = Size(width, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(config: config, logTabDefault: logTabDefault),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 200);
    await tester.pumpAndSettle();
  }

  test('new defaults: motion at 15 %, tag at 85 %, 100 events', () {
    const c = PresenceConfig();
    expect(c.motion.threshold, 15);
    expect(c.recognition.autoTag, 0.85);
    expect(c.subjects.mapEvents, 100);
    // Stored values are kept; only the defaults changed.
    final stored = PresenceConfig.fromJson({
      'version': 1,
      'motion': {'threshold': 10},
      'recognition': {'autoTag': 0.8, 'ask': 0.5},
      'subjects': {'mapEvents': 20},
    });
    expect(stored.motion.threshold, 10);
    expect(stored.recognition.autoTag, 0.8);
    expect(stored.subjects.mapEvents, 20);
  });

  for (final width in [320.0, 1280.0]) {
    testWidgets('clip sliders sit side by side, at ${width.round()} wide', (
      tester,
    ) async {
      await show(tester, width: width);
      final before = find.byKey(const Key('clip-before-slider'));
      final after = find.byKey(const Key('clip-after-slider'));
      await scrollTo(tester, after);
      expect(find.text('Before press'), findsOneWidget);
      expect(find.text('After press'), findsOneWidget);
      // Before on the left, after on the right, on one row.
      expect(tester.getTopLeft(before).dy, tester.getTopLeft(after).dy);
      expect(
        tester.getTopRight(before).dx,
        lessThanOrEqualTo(tester.getTopLeft(after).dx),
      );
      expect(tester.getTopRight(after).dx, lessThanOrEqualTo(width - 16));
      // No overflow.
      expect(tester.takeException(), isNull);

      // Each still sets its own duration.
      await tester.drag(
        find.descendant(of: before, matching: find.byType(Slider)),
        const Offset(500, 0),
      );
      await tester.drag(
        find.descendant(of: after, matching: find.byType(Slider)),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(config.clip.before, ClipConfig.max);
      expect(config.clip.after, ClipConfig.min);
      expect(find.text('60 s'), findsOneWidget);
      expect(find.text('5 s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the motion threshold reads 15 % of the picture', (tester) async {
    await show(tester);
    await scrollTo(tester, find.byKey(const Key('motion-threshold-slider')));
    expect(find.text('15 % of the picture'), findsOneWidget);
  });

  testWidgets('recognition: one level, to tag; below it, it asks', (
    tester,
  ) async {
    await show(tester);
    await scrollTo(tester, find.byKey(const Key('recognition-ask-note')));
    await tester.ensureVisible(
      find.byKey(const Key('recognition-auto-slider'), skipOffstage: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('85 % sure'), findsOneWidget);
    expect(find.byKey(const Key('recognition-ask-slider')), findsNothing);
    expect(find.text('Ask me when at least'), findsNothing);
  });

  testWidgets('the Log switch is in the Advanced section', (tester) async {
    await show(tester);
    final logSwitch = find.byKey(const Key('show-log-switch'));
    await scrollTo(tester, logSwitch);
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Log'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Advanced')).dy,
      lessThan(tester.getTopLeft(logSwitch).dy),
    );
    expect(find.text('Show the Log tab'), findsOneWidget);
  });

  testWidgets('without the Log switch, no Advanced section', (tester) async {
    await show(tester, logTabDefault: null);
    await scrollTo(tester, find.byKey(const Key('subject-events-slider')));
    expect(find.text('Advanced', skipOffstage: false), findsNothing);
  });
}
