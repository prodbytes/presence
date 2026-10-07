import 'package:flutter/material.dart';

/// Gruvbox dark palette (https://github.com/morhetz/gruvbox).
abstract final class Gruvbox {
  static const bg0Hard = Color(0xFF1D2021);
  static const bg0 = Color(0xFF282828);
  static const bg0Soft = Color(0xFF32302F);
  static const bg1 = Color(0xFF3C3836);
  static const bg2 = Color(0xFF504945);
  static const bg3 = Color(0xFF665C54);
  static const bg4 = Color(0xFF7C6F64);
  static const gray = Color(0xFF928374);

  static const fg0 = Color(0xFFFBF1C7);
  static const fg = Color(0xFFEBDBB2);
  static const fg2 = Color(0xFFD5C4A1);
  static const fg4 = Color(0xFFA89984);

  static const red = Color(0xFFFB4934);
  static const green = Color(0xFFB8BB26);
  static const yellow = Color(0xFFFABD2F);
  static const blue = Color(0xFF83A598);
  static const purple = Color(0xFFD3869B);
  static const aqua = Color(0xFF8EC07C);
  static const orange = Color(0xFFFE8019);
}

/// "Gruvbox dark, soft contrast": the page uses the soft background (bg0_s),
/// and panels and cards step up through bg1 and bg2.
ThemeData gruvboxSoftDarkTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Gruvbox.yellow,
    onPrimary: Gruvbox.bg0,
    primaryContainer: Gruvbox.bg2,
    onPrimaryContainer: Gruvbox.yellow,
    secondary: Gruvbox.aqua,
    onSecondary: Gruvbox.bg0,
    secondaryContainer: Gruvbox.bg2,
    onSecondaryContainer: Gruvbox.fg,
    tertiary: Gruvbox.blue,
    onTertiary: Gruvbox.bg0,
    tertiaryContainer: Gruvbox.bg2,
    onTertiaryContainer: Gruvbox.blue,
    error: Gruvbox.red,
    onError: Gruvbox.bg0,
    errorContainer: Gruvbox.bg2,
    onErrorContainer: Gruvbox.red,
    surface: Gruvbox.bg0Soft,
    onSurface: Gruvbox.fg,
    onSurfaceVariant: Gruvbox.fg4,
    surfaceContainerLowest: Gruvbox.bg0Hard,
    surfaceContainerLow: Gruvbox.bg1,
    surfaceContainer: Gruvbox.bg1,
    surfaceContainerHigh: Gruvbox.bg2,
    surfaceContainerHighest: Gruvbox.bg2,
    outline: Gruvbox.gray,
    outlineVariant: Gruvbox.bg3,
    inverseSurface: Gruvbox.fg,
    onInverseSurface: Gruvbox.bg0,
    inversePrimary: Gruvbox.orange,
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    colorScheme: scheme,
    // Every screen changes as the tabs do, on every platform.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: const TabSlidePageTransitionsBuilder(),
      },
    ),
    scaffoldBackgroundColor: scheme.surface,
    cardTheme: const CardThemeData(color: Gruvbox.bg1, elevation: 0),
    dividerTheme: const DividerThemeData(color: Gruvbox.bg2),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: Gruvbox.bg3,
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      textStyle: TextStyle(color: Gruvbox.fg0),
    ),
  );
}

/// A pushed screen (a subject's) slides in from the right as the one under
/// it slides out to the left, and back again on return: the same move,
/// curve and duration as flipping between the tabs (`TabBarView`), so
/// every view change looks alike.
class TabSlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const TabSlidePageTransitionsBuilder();

  /// The tabs' curve.
  static const Curve curve = Curves.ease;

  /// The tabs' duration.
  @override
  Duration get transitionDuration => kTabScrollDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).chain(CurveTween(curve: curve)).animate(animation),
    child: SlideTransition(
      position: Tween(
        begin: Offset.zero,
        end: const Offset(-1, 0),
      ).chain(CurveTween(curve: curve)).animate(secondaryAnimation),
      child: child,
    ),
  );
}
