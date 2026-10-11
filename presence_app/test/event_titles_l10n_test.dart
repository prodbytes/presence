import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/l10n/l10n.dart';
import 'package:presence_app/recognition/suggestion.dart';

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final es = lookupAppLocalizations(const Locale('es'));
  final pt = lookupAppLocalizations(const Locale('pt'));

  AppEvent generic(String title, [String? detail]) =>
      AppEvent(icon: Icons.info, title: title, detail: detail);

  test('in English an event shows exactly what is stored', () {
    for (final event in [
      AppEvent.appStarted(),
      AppEvent.captureAll(),
      generic('Recording consent given', 'automatic_paranoid_gadget'),
      generic('Signed in', 'someone@example.com'),
      generic('Motion detected', 'Clip recording missing'),
      generic('Something new', 'free text'),
      SubjectSuggestion(
        clipEventId: 'c',
        annotationId: 'a',
        subjectName: 'Rex',
        confidence: 0.734,
      ),
    ]) {
      expect(event.displayTitle(en), event.title);
      expect(event.displayDetail(en), event.detail);
    }
  });

  test('stored English titles show in the app language', () {
    expect(AppEvent.appStarted().displayTitle(es), 'Aplicación iniciada');
    expect(
      AppEvent.captureAll().displayDetail(pt),
      'Cada dispositivo grava um clipe',
    );
    expect(
      generic('Signed out', 'me@example.com').displayDetail(es),
      'me@example.com',
    );
    expect(generic('Something new').displayTitle(es), 'Something new');
    final suggestion = SubjectSuggestion(
      clipEventId: 'c',
      annotationId: 'a',
      subjectName: 'Rex',
      confidence: 0.9,
    );
    expect(suggestion.displayTitle(es), '¿Es Rex?');
    expect(suggestion.displayDetail(pt), '90 % de certeza');
    // What's stored stays English.
    expect(suggestion.toRecord()['title'], 'Is this Rex?');
  });

  test('the search finds an event by its stored and its shown title', () {
    final event = AppEvent.appStarted();
    expect(eventMatches(event, 'application', l: es), isTrue);
    expect(eventMatches(event, 'iniciada', l: es), isTrue);
    expect(eventMatches(event, 'iniciada'), isFalse);
  });
}
