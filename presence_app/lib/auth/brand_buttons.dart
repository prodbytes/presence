import 'package:flutter/material.dart';

/// The sign-in buttons' height: Apple's recommended minimum, and Google's
/// matches it (equal prominence, App Store guideline 4.8).
const double brandButtonHeight = 44;

/// "Sign in with Apple", per Apple's guidelines: the Apple logo and the
/// title on black in light mode, on white in dark mode.
class AppleSignInButton extends StatelessWidget {
  const AppleSignInButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.height = brandButtonHeight,
  });

  final String text;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _BrandButton(
      height: height,
      background: dark ? Colors.white : Colors.black,
      foreground: dark ? Colors.black : Colors.white,
      logo: Icon(
        Icons.apple,
        size: 20,
        color: dark ? Colors.black : Colors.white,
      ),
      text: text,
      onPressed: onPressed,
    );
  }
}

/// "Sign in with Google", per Google's branding guidelines: the four-colour
/// "G" on white with a grey border in light mode, on near-black in dark.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.height = brandButtonHeight,
  });

  final String text;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _BrandButton(
      height: height,
      background: dark ? const Color(0xFF131314) : Colors.white,
      foreground: dark ? const Color(0xFFE3E3E3) : const Color(0xFF1F1F1F),
      border: dark ? const Color(0xFF8E918F) : const Color(0xFF747775),
      logo: const SizedBox.square(
        dimension: 18,
        child: CustomPaint(painter: GoogleLogoPainter()),
      ),
      text: text,
      onPressed: onPressed,
    );
  }
}

/// A brand's sign-in button: its logo then its title, centred, on a pill.
class _BrandButton extends StatelessWidget {
  const _BrandButton({
    required this.height,
    required this.background,
    required this.foreground,
    required this.logo,
    required this.text,
    required this.onPressed,
    this.border,
  });

  final double height;
  final Color background;
  final Color foreground;
  final Color? border;
  final Widget logo;
  final String text;
  final VoidCallback? onPressed;

  bool get compact => height < brandButtonHeight;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        minimumSize: Size(0, height),
        maximumSize: Size(double.infinity, height),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // Smaller in an app bar, where the button sits beside its actions.
        padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16),
        backgroundColor: background,
        foregroundColor: foreground,
        side: border == null ? BorderSide.none : BorderSide(color: border!),
        shape: const StadiumBorder(),
        textStyle: TextStyle(
          fontSize: compact ? 14 : 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          logo,
          SizedBox(width: compact ? 8 : 10),
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// Google's four-colour "G", from its official 48×48 SVG.
class GoogleLogoPainter extends CustomPainter {
  const GoogleLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 48, size.height / 48);
    void fill(int color, Path path) =>
        canvas.drawPath(path, Paint()..color = Color(color));
    fill(
      0xFFEA4335,
      Path()
        ..moveTo(24, 9.5)
        ..cubicTo(27.54, 9.5, 30.71, 10.72, 33.21, 13.1)
        ..lineTo(40.06, 6.25)
        ..cubicTo(35.9, 2.38, 30.47, 0, 24, 0)
        ..cubicTo(14.62, 0, 6.51, 5.38, 2.56, 13.22)
        ..lineTo(10.54, 19.41)
        ..cubicTo(12.43, 13.72, 17.74, 9.5, 24, 9.5)
        ..close(),
    );
    fill(
      0xFF4285F4,
      Path()
        ..moveTo(46.98, 24.55)
        ..cubicTo(46.98, 22.98, 46.83, 21.46, 46.6, 20)
        ..lineTo(24, 20)
        ..lineTo(24, 29.02)
        ..lineTo(36.94, 29.02)
        ..cubicTo(36.36, 31.98, 34.68, 34.5, 32.16, 36.2)
        ..lineTo(39.89, 42.2)
        ..cubicTo(44.4, 38.02, 46.98, 31.84, 46.98, 24.55)
        ..close(),
    );
    fill(
      0xFFFBBC05,
      Path()
        ..moveTo(10.53, 28.59)
        ..cubicTo(10.05, 27.14, 9.77, 25.6, 9.77, 24)
        ..cubicTo(9.77, 22.4, 10.04, 20.86, 10.53, 19.41)
        ..lineTo(2.55, 13.22)
        ..cubicTo(0.92, 16.46, 0, 20.12, 0, 24)
        ..cubicTo(0, 27.88, 0.92, 31.54, 2.56, 34.78)
        ..lineTo(10.53, 28.59)
        ..close(),
    );
    fill(
      0xFF34A853,
      Path()
        ..moveTo(24, 48)
        ..cubicTo(30.48, 48, 35.93, 45.87, 39.89, 42.19)
        ..lineTo(32.16, 36.19)
        ..cubicTo(30.01, 37.64, 27.24, 38.49, 24, 38.49)
        ..cubicTo(17.74, 38.49, 12.43, 34.27, 10.53, 28.58)
        ..lineTo(2.55, 34.77)
        ..cubicTo(6.51, 42.62, 14.62, 48, 24, 48)
        ..close(),
    );
  }

  @override
  bool shouldRepaint(GoogleLogoPainter oldDelegate) => false;
}
