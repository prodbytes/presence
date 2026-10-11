import 'package:flutter/widgets.dart';

import 'gen/app_localizations.dart';

export 'gen/app_localizations.dart';

/// The app's strings in the language shown (Settings' **Language**, or the
/// device's): `context.l10n.languageSection`. Bundles in `parts/`, merged by
/// `scripts/l10n-merge.py` into `app_<lang>.arb`.
extension L10nContext on BuildContext {
  /// English where no localizations are set up above (widget tests that
  /// pump a bare `MaterialApp`), so text never goes missing.
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ?? lookupAppLocalizations(const Locale('en'));
}
