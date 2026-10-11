// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get languageEnglish => 'English';

  @override
  String get languageLabel => 'Idioma de la aplicación';

  @override
  String get languageNote =>
      'Los títulos de eventos guardados antes conservan el idioma en que se crearon.';

  @override
  String get languagePortuguese => 'Português';

  @override
  String get languageSection => 'Idioma';

  @override
  String get languageSpanish => 'Español';

  @override
  String get languageSystem => 'El mismo que el dispositivo';
}
