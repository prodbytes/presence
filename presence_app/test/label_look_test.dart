import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/subjects.dart';
import 'package:presence_app/theme.dart';

import 'fakes.dart';
import 'sealed.dart';

void main() {
  group('confidence stored with the labels', () {
    test('a tag someone made or confirmed is 100 % sure', () {
      final a = ClipAnnotations();
      final frame = testFrame(onePixelPng, 1000);
      final manual = a.add('Ana', 0.1, 0.1, frame: frame)!;
      final detected = a.add(
        'Rex',
        0.5,
        0.5,
        frame: frame,
        source: TagSource.detected,
        confidence: 0.7,
      )!;
      final suggested = a.add(
        'Bo',
        0.2,
        0.2,
        frame: frame,
        source: TagSource.suggested,
        confidence: 0.6,
      )!;
      expect(manual.confidence, 1);
      expect(a.toJson().first['confidence'], 1);
      a.confirm(suggested.id);
      expect(a.byId(suggested.id)!.confidence, 1);

      final back = ClipAnnotations.fromJson(a.toJson(), a.framesToRecord());
      expect(back.byId(manual.id)!.confidence, 1);
      expect(back.byId(detected.id)!.confidence, 0.7);
      expect(back.byId(suggested.id)!.confidence, 1);
    });

    test('older records: tags someone made read as 100 % sure', () {
      final back = ClipAnnotations.fromJson([
        {'id': 'a', 'name': 'Ana', 'x': 0.1, 'y': 0.1},
        {'id': 'b', 'name': 'Bo', 'x': 0.1, 'y': 0.1, 'source': 'confirmed'},
        {'id': 'r', 'name': 'Rex', 'x': 0.1, 'y': 0.1, 'source': 'detected'},
      ]);
      expect(back.byId('a')!.confidence, 1);
      expect(back.byId('b')!.confidence, 1);
      expect(back.byId('r')!.confidence, isNull);
    });
  });

  group('labelBorderColor', () {
    final scheme = gruvboxSoftDarkTheme().colorScheme;

    test("the theme's main color for one someone made or confirmed", () {
      expect(labelBorderColor(scheme, 1, authored: true), scheme.primary);
    });

    test("grey for recognition's, even at 100 %", () {
      final c = labelBorderColor(scheme, 1);
      expect(c, isNot(scheme.primary));
      expect(c.r, c.g);
      expect(c.g, c.b);
    });

    test('greys under 100 %, lighter the surer', () {
      final low = labelBorderColor(scheme, 0.3);
      final high = labelBorderColor(scheme, 0.9);
      for (final c in [low, high]) {
        expect(c, isNot(scheme.primary));
        expect(c.r, c.g);
        expect(c.g, c.b);
      }
      expect(high.computeLuminance(), greaterThan(low.computeLuminance()));
    });
  });

  testWidgets('subjects are round, tags square, colored only when authored', (
    tester,
  ) async {
    final annotations = ClipAnnotations(const [], const {}, const [
      ObjectTag(label: 'cat', ms: 1000, score: 0.9),
      ObjectTag(label: 'bottle', ms: 1000, score: 0.4),
      ObjectTag(label: 'dog', ms: 1000, score: 1),
    ]);
    final frame = testFrame(onePixelPng, 1200);
    annotations
      ..add('Ana', 0.5, 0.5, frame: frame)
      ..add(
        'Rex',
        0.4,
        0.4,
        frame: frame,
        source: TagSource.detected,
        confidence: 0.8,
      )
      // Recognition's first, 100 % sure: still grey.
      ..add(
        'Bo',
        0.3,
        0.3,
        frame: frame,
        source: TagSource.detected,
        confidence: 1,
      );
    final event = ClipRequested(
      VideoClip.restored(
        id: 'clip',
        cameraId: 'cam',
        cameraLabel: 'Back camera',
        before: const Duration(seconds: 15),
        after: const Duration(seconds: 15),
        past: null,
        full: null,
      ),
      annotations: annotations,
      time: DateTime(2026, 10, 1, 12),
      id: 'event',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: gruvboxSoftDarkTheme(),
        home: Scaffold(
          body: Column(
            children: [
              EventSubjects(event: event),
              ClipObjectTags(annotations: annotations),
            ],
          ),
        ),
      ),
    );
    final scheme = gruvboxSoftDarkTheme().colorScheme;

    BoxDecoration subject(String id) =>
        tester
                .widget<DecoratedBox>(
                  find.byKey(Key('event-subject-border-$id')),
                )
                .decoration
            as BoxDecoration;
    BoxDecoration tag(String label) =>
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byKey(Key('clip-object-chip-$label')),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;

    final ana = subject('ana');
    expect(ana.borderRadius, const BorderRadius.all(Radius.circular(999)));
    expect((ana.border! as Border).top.color, scheme.primary);
    expect(
      (subject('rex').border! as Border).top.color,
      labelBorderColor(scheme, 0.8),
    );
    expect(
      (subject('bo').border! as Border).top.color,
      allOf(labelBorderColor(scheme, 1), isNot(scheme.primary)),
    );

    final cat = tag('cat');
    expect(cat.borderRadius, isNull);
    expect((cat.border! as Border).top.color, labelBorderColor(scheme, 0.9));
    expect(
      (tag('bottle').border! as Border).top.color,
      labelBorderColor(scheme, 0.4),
    );
    expect(
      (tag('dog').border! as Border).top.color,
      allOf(labelBorderColor(scheme, 1), isNot(scheme.primary)),
    );
  });
}
