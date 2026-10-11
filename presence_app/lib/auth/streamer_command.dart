import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// The command that installs the Presence streamer on a Raspberry Pi for
/// [profileId]: the install script (served at
/// https://sh.presence.nu01.com/streamer) with the profile as its argument.
/// Profile IDs are lowercase letters and underscores, so it needs no
/// quoting; anything else gets none.
String? streamerCommand(String profileId) =>
    RegExp(r'^[a-z]+_[a-z]+_[a-z]+$').hasMatch(profileId)
    ? 'curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- $profileId'
    : null;

/// The account sheet's box for a premium profile: how to make a Raspberry
/// Pi stream into it, as one command to copy and paste on the Pi (see
/// specs/streamer.md and specs/install-script.md).
class StreamerCommand extends StatelessWidget {
  const StreamerCommand({super.key, required this.profileId});

  /// The signed-in account's profile (`RolesService.profile`).
  final String profileId;

  @override
  Widget build(BuildContext context) {
    final command = streamerCommand(profileId);
    if (command == null) return const SizedBox.shrink();
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const Key('streamer-command'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.developer_board, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.authStreamerTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l.authStreamerBody,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              command,
              key: const Key('streamer-command-text'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonalIcon(
              key: const Key('streamer-command-copy'),
              icon: const Icon(Icons.copy),
              label: Text(l.authStreamerCopy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l.authStreamerCopied)));
              },
            ),
          ),
        ],
      ),
    );
  }
}
