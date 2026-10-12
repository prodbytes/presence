import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../identity/device_id.dart';
import '../l10n/l10n.dart';
import 'auth_service.dart';
import 'profile_client.dart';

final _streamKey = RegExp(r'^psk_[A-Za-z0-9_-]{43}$');

/// The command that installs the Presence streamer on a Raspberry Pi as
/// [device] of [profileId], with its stream key [key]: the install script
/// (served at https://sh.presence.nu01.com/streamer) with the three as
/// options. Nobody signs in on the Pi, so it works headless. Every part
/// is letters, digits, `_` or `-`, so it needs no quoting; anything else
/// gets no command.
String? streamerCommand(String profileId, String device, String key) =>
    DeviceId.pattern.hasMatch(profileId) &&
        DeviceId.pattern.hasMatch(device) &&
        _streamKey.hasMatch(key)
    ? 'curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- '
          '--profile $profileId --device-id $device --key $key'
    : null;

/// The account sheet's box for a premium profile: how to make a Raspberry
/// Pi stream into it. **Create command** makes a new device for the Pi and
/// its stream key (`POST /api/auth/profile/stream-key`), and shows the one
/// command to copy and paste on the Pi; the key is shown only then (see
/// specs/streamer.md and specs/install-script.md).
class StreamerCommand extends StatefulWidget {
  const StreamerCommand({
    super.key,
    required this.profileId,
    required this.auth,
    required this.profiles,
  });

  /// The signed-in account's profile (`RolesService.profile`).
  final String profileId;
  final AuthService auth;
  final ProfileClient profiles;

  @override
  State<StreamerCommand> createState() => _StreamerCommandState();
}

class _StreamerCommandState extends State<StreamerCommand> {
  String? _command;
  bool _creating = false;
  String? _error;

  Future<void> _create() async {
    final token = widget.auth.idToken;
    if (token == null) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final key = await widget.profiles.streamKey(token, DeviceId.generate());
      final command = streamerCommand(key.profile, key.device, key.key);
      if (!mounted) return;
      setState(() {
        _command = command;
        _error = command == null ? 'unexpected answer' : null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!DeviceId.pattern.hasMatch(widget.profileId)) {
      return const SizedBox.shrink();
    }
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final command = _command;
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
          if (command != null) ...[
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
            const SizedBox(height: 4),
            Text(
              l.authStreamerKeyOnce,
              key: const Key('streamer-command-once'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            Text(
              l.authStreamerFailed(error),
              key: const Key('streamer-command-error'),
              style: TextStyle(color: scheme.error),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (command == null)
                  FilledButton.tonalIcon(
                    key: const Key('streamer-command-create'),
                    icon: _creating
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.key),
                    label: Text(l.authStreamerCreate),
                    onPressed: _creating ? null : _create,
                  )
                else
                  FilledButton.tonalIcon(
                    key: const Key('streamer-command-copy'),
                    icon: const Icon(Icons.copy),
                    label: Text(l.authStreamerCopy),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: command));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l.authStreamerCopied)),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
