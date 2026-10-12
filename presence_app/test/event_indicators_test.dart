import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/copies_badge.dart';

ClipRequested clip({ClipAnnotations? annotations}) => ClipRequested(
  VideoClip.restored(
    id: 'c1',
    cameraId: 'cam',
    cameraLabel: 'Back camera',
    before: const Duration(seconds: 15),
    after: const Duration(seconds: 15),
    past: null,
    full: null,
  ),
  id: 'e1',
  annotations: annotations,
);

void main() {
  Future<(Icon, String)> pump(WidgetTester tester, ClipRequested event) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: EventIndicators(event: event)),
      ),
    );
    final badge = find.byKey(const Key('event-recognition-e1'));
    final icon = tester.widget<Icon>(
      find.descendant(of: badge, matching: find.byType(Icon)),
    );
    final tooltip = tester
        .widget<Tooltip>(
          find.descendant(of: badge, matching: find.byType(Tooltip)),
        )
        .message!;
    return (icon, tooltip);
  }

  ColorScheme schemeOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(EventIndicators))).colorScheme;

  testWidgets('not run: disabled, and each part says not searched', (
    tester,
  ) async {
    final (icon, tooltip) = await pump(tester, clip());
    expect(icon.icon, Icons.psychology_outlined);
    expect(icon.color, schemeOf(tester).onSurface.withValues(alpha: 0.38));
    expect(
      tooltip,
      "Recognition hasn't run\n"
      'People and pets: not searched\n'
      'Object tags: not searched',
    );
  });

  testWidgets('searched in full, nothing found: on, and says so', (
    tester,
  ) async {
    final a = ClipAnnotations(const [], const {}, const [])
      ..setSubjectSearch(const SubjectSearch(SubjectSearchOutcome.searched, 5));
    final (icon, tooltip) = await pump(tester, clip(annotations: a));
    expect(icon.icon, Icons.psychology);
    expect(icon.color, schemeOf(tester).primary);
    expect(
      tooltip,
      'Recognition ran in full\n'
      'People and pets: searched, no one recognized\n'
      'Object tags: searched, nothing seen',
    );
  });

  testWidgets('searched in full, found: names and labels', (tester) async {
    final a = ClipAnnotations(
      [
        const Annotation(
          id: 'a',
          name: 'Rex',
          x: .5,
          y: .5,
          source: TagSource.detected,
        ),
        const Annotation(
          id: 'b',
          name: 'Ana',
          x: .5,
          y: .5,
          source: TagSource.suggested,
        ),
      ],
      const {},
      const [
        ObjectTag(label: 'dog', ms: 0, score: .9),
        ObjectTag(label: 'bicycle', ms: 0, score: .7),
      ],
    )..setSubjectSearch(const SubjectSearch(SubjectSearchOutcome.searched, 5));
    final (_, tooltip) = await pump(tester, clip(annotations: a));
    // A suggestion ("Is this Ana?") isn't someone found.
    expect(tooltip, contains('People and pets: Rex\n'));
    expect(tooltip, endsWith('Object tags: dog, bicycle'));
  });

  testWidgets('in part: plain, and says which part', (tester) async {
    // Object tags only (as the streamer's cloud detector stores them), and
    // nobody named yet to look for.
    var (icon, tooltip) = await pump(
      tester,
      clip(annotations: ClipAnnotations(const [], const {}, const [])),
    );
    expect(icon.icon, Icons.psychology);
    expect(icon.color, schemeOf(tester).onSurfaceVariant);
    expect(
      tooltip,
      startsWith('Recognition ran in part\nPeople and pets: not searched'),
    );

    final none = ClipAnnotations()
      ..setSubjectSearch(
        const SubjectSearch(SubjectSearchOutcome.noReferences, 5),
      );
    (icon, tooltip) = await pump(tester, clip(annotations: none));
    expect(
      tooltip,
      'Recognition ran in part\n'
      'People and pets: no one named yet to look for\n'
      'Object tags: not searched',
    );
  });

  test('the subject search is kept in the record, and comes back', () {
    final a = ClipAnnotations(const [], const {}, const [])
      ..setSubjectSearch(
        const SubjectSearch(SubjectSearchOutcome.allTagged, 42),
      );
    final record = clip(annotations: a).toRecord();
    expect(record['subjectSearch'], {'outcome': 'allTagged', 'at': 42});
    final back = ClipAnnotations.fromJson(
      record['annotations'],
      null,
      record['objectTags'],
      record['subjectSearch'],
    );
    expect(
      back.subjectSearch,
      const SubjectSearch(SubjectSearchOutcome.allTagged, 42),
    );
    // Missing or damaged: not searched.
    expect(ClipAnnotations.fromJson(null).subjectSearch, isNull);
    expect(
      ClipAnnotations.fromJson(null, null, null, {
        'outcome': 'later',
        'at': 1,
      }).subjectSearch,
      isNull,
    );
    expect(clip().toRecord().containsKey('subjectSearch'), isFalse);
  });

  test('a search noted on either copy stays noted', () {
    final here = ClipAnnotations()
      ..setSubjectSearch(const SubjectSearch(SubjectSearchOutcome.searched, 1));
    here.replaceWith(ClipAnnotations());
    expect(here.subjectSearch?.outcome, SubjectSearchOutcome.searched);
    here.replaceWith(
      ClipAnnotations()..setSubjectSearch(
        const SubjectSearch(SubjectSearchOutcome.allTagged, 2),
      ),
    );
    expect(here.subjectSearch?.outcome, SubjectSearchOutcome.allTagged);
  });
}
