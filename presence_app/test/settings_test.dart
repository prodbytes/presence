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
    bool liveSync = false,
    bool liveAdmin = false,
  }) async {
    tester.view.physicalSize = Size(width, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            config: config,
            logTabDefault: logTabDefault,
            liveSync: liveSync,
            liveAdmin: liveAdmin,
          ),
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

  testWidgets('a slider shows its value while dragged, and changes the '
      'setting (saved and synced) once, when let go', (tester) async {
    await show(tester);
    final slider = find.byKey(const Key('motion-threshold-slider'));
    await scrollTo(tester, slider);
    var changes = 0;
    void count() => changes++;
    config.addListener(count);
    addTearDown(() => config.removeListener(count));

    final bar = find.descendant(of: slider, matching: find.byType(Slider));
    final drag = await tester.startGesture(tester.getCenter(bar));
    for (var i = 0; i < 5; i++) {
      await drag.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    // Dragging: the label follows, the setting doesn't change yet.
    expect(changes, 0);
    expect(config.motion.threshold, 15);
    final shown = tester.widget<Slider>(bar).value;
    expect(shown, greaterThan(15));
    expect(find.text('${shown.round()} % of the picture'), findsOneWidget);

    await drag.up();
    await tester.pumpAndSettle();
    expect(changes, 1);
    expect(config.motion.threshold, shown.roundToDouble());
    expect(find.text('${shown.round()} % of the picture'), findsOneWidget);
  });

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

  testWidgets('Connect to live sync: a slider from Never to every 60 min, '
      'every minute by default; only with live sync', (tester) async {
    await show(tester);
    expect(find.byKey(const Key('live-connect-slider')), findsNothing);

    await show(tester, liveSync: true, logTabDefault: null);
    final slider = find.byKey(const Key('live-connect-slider'));
    await scrollTo(tester, slider);
    expect(find.text('Connect to live sync'), findsOneWidget);
    expect(find.text('Every 1 min'), findsOneWidget);
    final bar = find.descendant(of: slider, matching: find.byType(Slider));
    expect(tester.widget<Slider>(bar).divisions, LiveConfig.memberMaxStep);

    // All the way left: Never; all the way right: every 60 min (Always
    // is for admins).
    await tester.drag(bar, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(config.live, LiveConfig.never);
    expect(find.text('Never'), findsOneWidget);
    await tester.drag(bar, const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(config.live, const LiveConfig(every: Duration(minutes: 60)));
    expect(find.text('Every 60 min'), findsOneWidget);
    expect(find.text('Always'), findsNothing);
  });

  testWidgets('Connect to live sync: every 30 s the most often for members; '
      'a saved Always shows as every 30 s', (tester) async {
    config.update(
      (x) => x.copyWith(live: const LiveConfig(every: Duration(seconds: 30))),
    );
    await show(tester, liveSync: true, logTabDefault: null);
    final slider = find.byKey(const Key('live-connect-slider'));
    await scrollTo(tester, slider);
    expect(find.text('Every 30 s'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('live-connect-note'))).data,
      contains('every 30 s'),
    );

    config.update((x) => x.copyWith(live: LiveConfig.always));
    await tester.pumpAndSettle();
    expect(find.text('Every 30 s'), findsOneWidget);
    expect(find.text('Always'), findsNothing);
    // What's saved stays: an admin's again would be Always.
    expect(config.live, LiveConfig.always);
  });

  testWidgets('Connect to live sync: admins are always connected, the '
      'slider locked at Always', (tester) async {
    await show(tester, liveSync: true, liveAdmin: true, logTabDefault: null);
    final slider = find.byKey(const Key('live-connect-slider'));
    await scrollTo(tester, slider);
    expect(find.text('Always'), findsOneWidget);
    final bar = find.descendant(of: slider, matching: find.byType(Slider));
    expect(tester.widget<Slider>(bar).onChanged, isNull);
    expect(tester.widget<Slider>(bar).value, LiveConfig.steps - 1);
    expect(
      tester.widget<Text>(find.byKey(const Key('live-connect-note'))).data,
      contains('Always connected for admins'),
    );
    await tester.drag(bar, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    // Unchanged: every minute, the default, saved for when they're not.
    expect(config.live, const LiveConfig());
    expect(find.text('Always'), findsOneWidget);
  });

  for (final (width, scale, columns) in [
    (320.0, 1.0, true),
    (320.0, 2.0, false),
    (1280.0, 1.0, true),
    (1280.0, 2.0, true),
  ]) {
    testWidgets('the device and profile IDs come first, bodyMedium, '
        '${columns ? 'in two columns' : 'stacked'}, and fit '
        '${width.round()} dp at ${scale}x text', (tester) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 640),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: SettingsView(
                config: config,
                deviceId: 'automatic_paranoid_gadget',
                profileId: 'automatic_paranoid_axolotl',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Shown without scrolling; the IDs never overflow (other rows may
      // at 2x and 320 dp).
      final error = tester.takeException();
      if (scale == 1) expect(error, isNull);
      expect(error.toString(), isNot(contains('_IdLine')));

      final body = Theme.of(tester.element(find.byType(SettingsView)))
          .textTheme;
      final device = find.byKey(const Key('device-id'));
      final profile = find.byKey(const Key('profile-id'));
      for (final id in [device, profile]) {
        final style = tester.widget<SelectableText>(id).style!;
        expect(style.fontSize, body.bodyMedium!.fontSize);
        expect(style.fontSize, greaterThan(body.bodySmall!.fontSize!));
        // Inside the screen, not cut off, and visible at the top.
        expect(tester.getTopLeft(id).dx, greaterThanOrEqualTo(0));
        expect(tester.getTopRight(id).dx, lessThanOrEqualTo(width));
        expect(tester.getBottomLeft(id).dy, lessThanOrEqualTo(640));
      }
      expect(
        tester.widget<SelectableText>(device).data,
        'automatic_paranoid_gadget',
      );
      // The first content: above the first section's title.
      final ids = find.byKey(const Key('settings-ids'));
      expect(
        tester.getBottomLeft(ids).dy,
        lessThan(tester.getTopLeft(find.text('Camera')).dy),
      );
      expect(tester.getTopLeft(ids).dy, lessThanOrEqualTo(16));
      if (columns) {
        // Device left, Profile right, on the same line.
        expect(tester.getTopLeft(device).dy, tester.getTopLeft(profile).dy);
        expect(
          tester.getTopRight(device).dx,
          lessThan(tester.getTopLeft(profile).dx),
        );
      } else {
        // Stacked: Profile under Device.
        expect(
          tester.getTopLeft(profile).dy,
          greaterThan(tester.getBottomLeft(device).dy),
        );
      }
      // Each label is above its ID, the same size.
      for (final (label, id) in [('Device', device), ('Profile', profile)]) {
        final text = find.text(label);
        expect(
          tester.widget<Text>(text).style!.fontSize,
          body.bodyMedium!.fontSize,
        );
        expect(
          tester.getBottomLeft(text).dy,
          lessThanOrEqualTo(tester.getTopLeft(id).dy),
        );
      }
    });
  }
}
