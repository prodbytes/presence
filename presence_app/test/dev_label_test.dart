import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/main.dart';

void main() {
  Future<void> show(WidgetTester tester, Widget label, {double width = 400}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                // As in the app bar: the title, then the label.
                child: Row(
                  spacing: 8,
                  children: [
                    const Flexible(child: Text('Presence')),
                    Flexible(child: label),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('shows the version inside the dev label', (tester) async {
    await show(tester, const DevModeLabel(version: '0.4.202610011728'));
    expect(find.text('dev 0.4.202610011728'), findsOneWidget);
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      startsWith('Development mode, version 0.4.202610011728:'),
    );
  });

  testWidgets('without a build version, just "dev"', (tester) async {
    await show(tester, const DevModeLabel(version: ''));
    expect(find.text('dev'), findsOneWidget);
  });

  testWidgets('where there is no room, it is cut short, not overflowing', (
    tester,
  ) async {
    await show(
      tester,
      const DevModeLabel(version: '0.4.202610011728'),
      width: 120,
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const Key('dev-mode'))).right,
      lessThanOrEqualTo(tester.getRect(find.byType(Row)).right),
    );
  });
}
