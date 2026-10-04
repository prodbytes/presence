import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/app_log.dart';
import 'package:presence_app/log_view.dart';

void main() {
  test('keeps the latest entries, up to its capacity', () async {
    final log = AppLog(capacity: 2);
    var told = 0;
    log.addListener(() => told++);
    log
      ..add('one')
      ..add('two')
      ..add('three', error: true);
    expect(log.entries.map((e) => e.message), ['two', 'three']);
    expect(log.entries.last.error, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(told, 1, reason: 'one notification per burst');
    log.clear();
    expect(log.entries, isEmpty);
  });

  testWidgets('the Log tab lists the newest first, and clears', (tester) async {
    final log = AppLog(now: () => DateTime(2026, 10, 4, 9, 5, 7))
      ..add('Presence: older')
      ..add('Presence: cloud sync failed: S3 HTTP 403: denied', error: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogView(log: log)),
      ),
    );
    await tester.pump();
    final older = tester.getTopLeft(find.text('Presence: older'));
    final newer = tester.getTopLeft(
      find.text('Presence: cloud sync failed: S3 HTTP 403: denied'),
    );
    expect(newer.dy, lessThan(older.dy));
    expect(find.text('09:05:07'), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('log-clear')));
    await tester.pump();
    expect(find.text('Nothing logged yet.'), findsOneWidget);
  });
}
