import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/barrel_roll.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/monitoring.dart';

void main() {
  test('asks: "do a barrel roll", any case and spacing, or "barrell"', () {
    expect(BarrelRoll.asks('do a barrel roll'), isTrue);
    expect(BarrelRoll.asks('  Do a  BARREL roll '), isTrue);
    expect(BarrelRoll.asks('do a barrell roll'), isTrue);
    expect(BarrelRoll.asks('barrel roll'), isFalse);
    expect(BarrelRoll.asks('do a barrel roll now'), isFalse);
    expect(BarrelRoll.asks(''), isFalse);
  });

  group('the events search', () {
    late StreamController<AppEvent> bus;
    late EventLog log;

    setUp(() {
      bus = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream);
    });
    tearDown(() => bus.close());

    Future<void> show(WidgetTester tester, {bool reduceMotion = false}) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: reduceMotion),
            child: BarrelRoll(child: app!),
          ),
          home: Scaffold(
            body: MonitoringView(
              log: log,
              config: ConfigController(),
              tiles: const SizedBox(),
              deviceId: 'this_device',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('event-search-open')));
      await tester.pumpAndSettle();
    }

    double angle(WidgetTester tester) {
      final m = tester
          .widget<Transform>(find.byKey(const Key('barrel-roll')))
          .transform;
      // The rotation's sine, as the 2D rotation's (1, 0) entry.
      return m.entry(1, 0);
    }

    Future<void> type(WidgetTester tester, String text) =>
        tester.enterText(find.byKey(const Key('event-search')), text);

    /// A quarter of a turn's time on: the first frame starts the turn.
    Future<void> quarter(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(BarrelRoll.duration ~/ 4);
    }

    testWidgets('spins the screen once, then comes back level', (tester) async {
      await show(tester);
      expect(angle(tester), 0);

      await type(tester, 'Do a barrel roll');
      await quarter(tester);
      expect(angle(tester), isNot(closeTo(0, 0.01)));

      await tester.pumpAndSettle();
      expect(angle(tester), 0);
      // The search is kept: the app wasn't rebuilt from scratch.
      expect(find.text('Do a barrel roll'), findsOneWidget);
    });

    testWidgets('rolls once as the phrase is finished, again on submit', (
      tester,
    ) async {
      await show(tester);
      await type(tester, 'do a barrel roll');
      await tester.pumpAndSettle();

      // A space more still asks, but doesn't roll again.
      await type(tester, 'do a barrel roll ');
      await quarter(tester);
      expect(angle(tester), 0);

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await quarter(tester);
      expect(angle(tester), isNot(closeTo(0, 0.01)));
      await tester.pumpAndSettle();
    });

    testWidgets('other searches don\'t roll', (tester) async {
      await show(tester);
      await type(tester, 'barrel');
      await quarter(tester);
      expect(angle(tester), 0);
    });

    testWidgets('not with reduced motion', (tester) async {
      await show(tester, reduceMotion: true);
      await type(tester, 'do a barrel roll');
      await quarter(tester);
      expect(angle(tester), 0);
    });
  });
}
