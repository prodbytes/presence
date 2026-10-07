import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/theme.dart';

void main() {
  test('every platform changes screens as the tabs do', () {
    final builders = gruvboxSoftDarkTheme().pageTransitionsTheme.builders;
    for (final platform in TargetPlatform.values) {
      expect(builders[platform], isA<TabSlidePageTransitionsBuilder>());
    }
    expect(
      const TabSlidePageTransitionsBuilder().transitionDuration,
      kTabScrollDuration,
    );
  });

  testWidgets('a pushed screen slides in from the right, the other out left', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: gruvboxSoftDarkTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('pushed')),
                ),
              ),
              child: const Text('home'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    // Halfway: side by side, neither faded nor scaled.
    final pushed = tester.getTopLeft(find.text('pushed')).dx;
    final home = tester.getTopLeft(find.text('home')).dx;
    expect(pushed, greaterThan(0));
    expect(pushed, lessThan(400));
    expect(home, lessThan(0));
    expect(pushed - home, closeTo(400, 50));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('pushed')).dx, 0);

    // Back: the reverse.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(find.text('pushed')).dx, greaterThan(0));
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsNothing);
  });
}
