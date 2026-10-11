import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/l10n/l10n.dart';
import 'package:presence_app/settings.dart';

import 'fakes.dart';

void main() {
  group('the language setting', () {
    test('round-trips, follows the device by default, ignores the unknown', () {
      expect(const PresenceConfig().language.code, isNull);
      expect(const PresenceConfig().language.locale, isNull);
      final es = const PresenceConfig().copyWith(
        language: const LanguageConfig().withCode('es'),
      );
      expect(es.language.locale, const Locale('es'));
      expect(PresenceConfig.fromJson(es.toJson()), es);
      expect(es.toJson()['language'], {'code': 'es'});
      expect(
        PresenceConfig.fromJson({
          'language': {'code': 'fr'},
        }).language.code,
        isNull,
      );
      // Older records, without it.
      expect(PresenceConfig.fromJson(const {}).language.code, isNull);
    });

    Future<ConfigController> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final config = ConfigController();
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: config,
          builder: (context, _) => MaterialApp(
            locale: config.config.language.locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: SettingsView(config: config)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return config;
    }

    Future<void> pick(WidgetTester tester, String code) async {
      final picker = find.byKey(const Key('language-picker'));
      await tester.scrollUntilVisible(picker, 200);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('language-$code')).last);
      await tester.pumpAndSettle();
    }

    testWidgets('picking Español and Português switches the app', (
      tester,
    ) async {
      final config = await show(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('language-picker')),
        200,
      );
      await tester.pumpAndSettle();
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('Same as the device'), findsOneWidget);

      await pick(tester, 'es');
      expect(config.config.language.code, 'es');
      expect(find.text('Idioma de la aplicación'), findsOneWidget);
      expect(find.text('Language'), findsNothing);

      await pick(tester, 'pt');
      expect(config.config.language.code, 'pt');
      expect(find.text('Idioma do aplicativo'), findsOneWidget);

      await pick(tester, 'en');
      expect(config.config.language.code, 'en');
      expect(find.text('App language'), findsOneWidget);
    });
  });

  test('every bundle has every message, with the same placeholders', () {
    Map<String, Object?> read(String lang) =>
        (jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map)
            .cast<String, Object?>();
    final en = read('en');
    final keys = {
      for (final k in en.keys)
        if (!k.startsWith('@')) k,
    };
    final placeholder = RegExp(r'\{(\w+)[,}]');
    for (final lang in ['es', 'pt']) {
      final other = read(lang);
      expect(
        {
          for (final k in other.keys)
            if (!k.startsWith('@')) k,
        },
        keys,
        reason: lang,
      );
      for (final key in keys) {
        final text = other[key]! as String;
        expect(text.trim(), isNotEmpty, reason: '$lang $key');
        expect(
          placeholder.allMatches(text).map((m) => m[1]).toSet(),
          placeholder.allMatches(en[key]! as String).map((m) => m[1]).toSet(),
          reason: '$lang $key: placeholders',
        );
      }
    }
  });

  test('English is the fallback without localizations', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(en.languageSection, 'Language');
    expect(
      lookupAppLocalizations(const Locale('es')).languageSection,
      'Idioma',
    );
    expect(
      lookupAppLocalizations(const Locale('pt')).languageSection,
      'Idioma',
    );
  });

  for (final locale in const [Locale('es'), Locale('pt')]) {
    testWidgets('in ${locale.languageCode}, every tab fits a 320 dp phone', (
      tester,
    ) async {
      tester.platformDispatcher.localeTestValue = locale;
      tester.platformDispatcher.localesTestValue = [locale];
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          storage: newIdbFactoryMemory(),
          cameras: noCameras,
          auth: FakeAuthService.signedIn(),
          rolesClient: FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final l = lookupAppLocalizations(locale);
      // The device's language, Settings left at its default.
      expect(find.text(l.navSettings), findsWidgets);
      final tabs = tester
          .widget<HomeNavigationBar>(find.byType(HomeNavigationBar))
          .controller;
      for (var i = 0; i < tabs.length; i++) {
        tabs.animateTo(i);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'tab $i');
        // Down to the end of a scrolling tab (Settings is long).
        final lists = find.byType(Scrollable);
        for (var step = 0; step < 30 && lists.evaluate().isNotEmpty; step++) {
          await tester.drag(lists.first, const Offset(0, -300));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'tab $i, step $step');
        }
      }
    });
  }
}
