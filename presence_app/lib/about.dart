import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

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
/// is: the end of the account sheet.
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
      ],
    );
  }
}
