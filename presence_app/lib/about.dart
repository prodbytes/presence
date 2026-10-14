import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'auth/api_config.dart';
import 'l10n/l10n.dart';

/// Opens [url] outside the app; false when it couldn't.
typedef LinkOpener = Future<bool> Function(Uri url);

/// Opens [url] in the browser (the default [LinkOpener]).
Future<bool> launchLink(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Opens [url] with [openLink]; one that can't open is copied instead,
/// with a "Link copied" message.
Future<void> openOrCopyLink(
  BuildContext context,
  Uri url,
  LinkOpener openLink,
) async {
  if (await openLink(url)) return;
  Clipboard.setData(ClipboardData(text: '$url'));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.aboutLinkCopied)));
  }
}

/// What Presence is, in a paragraph, closing with a line on where its code
/// is and the [LegalLinks]: the end of the account sheet.
class AboutParagraph extends StatelessWidget {
  const AboutParagraph({super.key, LinkOpener? openLink})
    : openLink = openLink ?? launchLink;

  /// Opens a link; a link that can't open is copied instead.
  final LinkOpener openLink;

  static final source = Uri.parse('https://github.com/prodbytes/presence');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      key: const Key('about'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.aboutParagraph, style: muted),
        const SizedBox(height: 4),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(context.l10n.aboutOpenSource, style: muted),
            TextButton(
              key: const Key('about-source'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                textStyle: theme.textTheme.bodySmall,
              ),
              onPressed: () => openOrCopyLink(context, source, openLink),
              child: Text('${source.host}${source.path}'),
            ),
          ],
        ),
        LegalLinks(openLink: openLink),
      ],
    );
  }
}

/// The site's Privacy Policy and Terms of Service, on the same site as
/// the app's API ([ApiConfig.baseUrl]): the page's own on web,
/// presence.nu01.com (or `API_BASE_URL`, e.g. the RC's) on Android and iOS.
abstract final class LegalPages {
  static Uri get privacy => ApiConfig.baseUrl.resolve('/privacy');
  static Uri get terms => ApiConfig.baseUrl.resolve('/tos');
}

/// "Privacy Policy · Terms of Service", two small links opened outside the
/// app ([openOrCopyLink]): in the About paragraph, on the consent screen,
/// and signed out at the bottom of the camera ([SignedOutLegalLinks]).
class LegalLinks extends StatelessWidget {
  const LegalLinks({
    super.key,
    LinkOpener? openLink,
    this.alignment,
    this.color,
  }) : openLink = openLink ?? launchLink;

  /// Opens a link; a link that can't open is copied instead.
  final LinkOpener openLink;

  /// How the links line up; the start by default.
  final WrapAlignment? alignment;

  /// The links' color; the theme's by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TextButton.styleFrom(
      foregroundColor: color,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      minimumSize: const Size(0, 32),
      textStyle: theme.textTheme.bodySmall,
    );
    return Wrap(
      key: const Key('legal-links'),
      alignment: alignment ?? WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton(
          key: const Key('legal-privacy'),
          style: style,
          onPressed: () =>
              openOrCopyLink(context, LegalPages.privacy, openLink),
          child: Text(context.l10n.legalPrivacy),
        ),
        Text(
          '·',
          style: theme.textTheme.bodySmall?.copyWith(
            color: color ?? theme.colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton(
          key: const Key('legal-terms'),
          style: style,
          onPressed: () => openOrCopyLink(context, LegalPages.terms, openLink),
          child: Text(context.l10n.legalTerms),
        ),
      ],
    );
  }
}

/// Signed out there's no account sheet, and nothing at the bottom of the
/// camera: the [LegalLinks] sit there, centred on a dark scrim.
class SignedOutLegalLinks extends StatelessWidget {
  const SignedOutLegalLinks({super.key, this.openLink});

  /// Opens a link; the browser by default.
  final LinkOpener? openLink;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Positioned(
      left: 16 + padding.left,
      right: 16 + padding.right,
      bottom: 16 + padding.bottom,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: LegalLinks(
              openLink: openLink,
              alignment: WrapAlignment.center,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
