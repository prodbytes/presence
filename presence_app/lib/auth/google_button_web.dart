import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as gsi;

/// On web, Google requires its own button to sign in.
Widget? googleSignInButton() => gsi.renderButton(
  configuration: gsi.GSIButtonConfiguration(
    theme: gsi.GSIButtonTheme.filledBlack,
    size: gsi.GSIButtonSize.medium, // Fits the app bar.
    text: gsi.GSIButtonText.signinWith,
    shape: gsi.GSIButtonShape.pill,
  ),
);
