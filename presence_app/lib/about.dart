import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [url] outside the app; false when it couldn't.
typedef LinkOpener = Future<bool> Function(Uri url);

Future<bool> _launch(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// What Presence is, in a paragraph, closing with a line on where its code
/// is: the end of the account sheet.
class AboutParagraph extends StatelessWidget {
  const AboutParagraph({super.key, LinkOpener? openLink})
    : openLink = openLink ?? _launch;

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
        Text(
          'Presence turns a phone, tablet, laptop or Raspberry Pi into an '
          'always-on camera for a place you look after: live feeds, clips '
          'that include the moments before, and clips on motion. Only record '
          'where you\'re allowed to.',
          style: muted,
        ),
        const SizedBox(height: 4),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Presence is open source:', style: muted),
            TextButton(
              key: const Key('about-source'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                textStyle: theme.textTheme.bodySmall,
              ),
              onPressed: () async {
                if (await openLink(source)) return;
                Clipboard.setData(ClipboardData(text: '$source'));
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Link copied')));
                }
              },
              child: Text('${source.host}${source.path}'),
            ),
          ],
        ),
      ],
    );
  }
}
