import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import 'join_link.dart';

/// Near the end of Settings (above the IDs): a QR code of [link]
/// ([JoinLink.build]), to scan with another device, the link itself, and
/// buttons to share or copy it. The other device opens Presence (the app,
/// where it's installed and handles the link, or else the site) as a new
/// device of the same user.
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.settingsAddDeviceLinkCopied)),
    );
  }

  /// The system's share sheet (the Web Share API on web); copies the link
  /// where there's none.
  static Future<void> _share(BuildContext context, Uri link) async {
    final box = context.findRenderObject() as RenderBox?;
    final title = context.l10n.settingsAddDeviceShareTitle;
    try {
      await SharePlus.instance.share(
        ShareParams(
          uri: link,
          title: title,
          subject: title,
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
    final l = context.l10n;
    return Column(
      key: const Key('add-device'),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 8,
          children: [
            const Icon(Icons.qr_code_2),
            Text(l.settingsAddDeviceTitle, style: theme.textTheme.titleMedium),
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
              semanticsLabel: l.settingsAddDeviceQr('$link'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          switch (email) {
            final email? => l.settingsAddDeviceScanAs(email),
            null => l.settingsAddDeviceScan,
          },
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
              label: Text(l.settingsAddDeviceCopy),
              onPressed: () => _copy(context, link),
            ),
            Builder(
              builder: (context) => FilledButton.icon(
                key: const Key('add-device-share'),
                icon: const Icon(Icons.share),
                label: Text(l.settingsAddDeviceShare),
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
    final l = context.l10n;
    final (icon, message) = switch (status) {
      JoinStatus.signIn => (Icons.login, l.settingsJoinSignIn),
      JoinStatus.otherUser => (
        Icons.no_accounts,
        switch (email) {
          final email? => l.settingsJoinOtherUser(email),
          null => l.settingsJoinOtherUserUnknown,
        },
      ),
      JoinStatus.sameDevice => (Icons.devices, l.settingsJoinSameDevice),
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
              TextButton(
                onPressed: onSignOut,
                child: Text(l.settingsJoinSignOut),
              ),
            IconButton(
              tooltip: l.settingsJoinDismiss,
              icon: const Icon(Icons.close),
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
