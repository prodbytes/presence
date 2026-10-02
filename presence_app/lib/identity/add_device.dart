import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'join_link.dart';

/// The last thing in Settings: a QR code of [link] ([JoinLink.build]), to
/// scan with another device, the link itself, and buttons to share or copy
/// it. The other device opens Presence (the app, where it's installed and
/// handles the link, or else the site) as a new device of the same user.
class AddDeviceSection extends StatelessWidget {
  const AddDeviceSection({super.key, required this.link, this.email});

  /// The join link for this device and user.
  final Uri link;

  /// Who is signed in, to say whose device the new one will be.
  final String? email;

  /// Copies the link, and says so.
  static Future<void> _copy(BuildContext context, Uri link) async {
    await Clipboard.setData(ClipboardData(text: '$link'));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Link copied')));
  }

  /// The system's share sheet (the Web Share API on web); copies the link
  /// where there's none.
  static Future<void> _share(BuildContext context, Uri link) async {
    final box = context.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          uri: link,
          title: 'Open Presence',
          subject: 'Open Presence',
          // Anchors the sheet on iPads and Macs.
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
          mailToFallbackEnabled: false,
        ),
      );
    } catch (_) {
      if (context.mounted) await _copy(context, link);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final who = email == null ? '' : ' as $email';
    return Column(
      key: const Key('add-device'),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: [
            const Icon(Icons.qr_code_2),
            Text('Add a device', style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 12),
        // Dark on white, with a quiet zone, as scanners expect.
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(12),
          child: SizedBox.square(
            dimension: 200,
            child: QrImageView(
              key: const Key('add-device-qr'),
              data: '$link',
              size: 200,
              padding: EdgeInsets.zero,
              semanticsLabel: 'QR code for $link',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Scan with another device to open Presence there$who. '
          'It becomes a new device, with its own ID.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        SelectableText(
          '$link',
          key: const Key('add-device-link'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton.icon(
              key: const Key('add-device-copy'),
              icon: const Icon(Icons.copy),
              label: const Text('Copy link'),
              onPressed: () => _copy(context, link),
            ),
            Builder(
              builder: (context) => FilledButton.icon(
                key: const Key('add-device-share'),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
                onPressed: () => _share(context, link),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// On a device opened with a [JoinLink]: what's left to do (sign in as the
/// user who shared it), or what's wrong (another user, the same device).
/// [JoinStatus.joined] and [JoinStatus.waiting] show nothing.
class JoinBanner extends StatelessWidget {
  const JoinBanner({
    super.key,
    required this.status,
    this.email,
    this.onSignOut,
    required this.onDismiss,
  });

  final JoinStatus status;

  /// Who is signed in.
  final String? email;

  /// Signs out, to sign in as the right user ([JoinStatus.otherUser]).
  final VoidCallback? onSignOut;

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (icon, message) = switch (status) {
      JoinStatus.signIn => (
        Icons.login,
        'To add this device, sign in with the Google account that shared '
            'the link.',
      ),
      JoinStatus.otherUser => (
        Icons.no_accounts,
        'The link was shared by another Google account than '
            '${email ?? 'yours'}. Sign out, and sign in with that one, to add '
            'this device.',
      ),
      JoinStatus.sameDevice => (
        Icons.devices,
        'This is the device that shared the link. Open it on another '
            'device to add that one.',
      ),
      JoinStatus.waiting || JoinStatus.joined => (null, null),
    };
    if (icon == null || message == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('join-banner'),
      color: scheme.surfaceContainerHigh,
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          spacing: 12,
          children: [
            Icon(icon, color: scheme.primary),
            Expanded(child: Text(message)),
            if (status == JoinStatus.otherUser && onSignOut != null)
              TextButton(onPressed: onSignOut, child: const Text('Sign out')),
            IconButton(
              tooltip: 'Dismiss',
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
