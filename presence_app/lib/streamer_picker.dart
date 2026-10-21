import 'package:flutter/material.dart';

import 'config.dart';
import 'l10n/l10n.dart';

/// The streamer a camera integration goes through (specs/blink.md): the one
/// [chosen] in Settings while it's among [streamers], else the [leader],
/// else the first. Null when there are none.
String? streamerTarget(
  List<String> streamers, {
  String? chosen,
  String? leader,
}) {
  if (streamers.isEmpty) return null;
  if (chosen != null && streamers.contains(chosen)) return chosen;
  if (leader != null && streamers.contains(leader)) return leader;
  return streamers.first;
}

/// A camera integration's streamer dropdown: first **Leader** (the
/// default: whichever streamer leads), then each of [streamers]. Picking
/// one keeps it in [IntegrationsConfig] for [integration]; picking Leader
/// again clears it.
class StreamerPicker extends StatelessWidget {
  const StreamerPicker({
    super.key,
    required this.integration,
    required this.streamers,
    required this.leader,
    required this.config,
    required this.label,
    required this.onChanged,
  });

  /// The dropdown's value for Leader (a device ID is never empty).
  static const String leaderValue = '';

  /// `blink`, `gopro`, `reolink` or `usbcam` ([IntegrationsConfig.known]).
  final String integration;
  final List<String> streamers;
  final String? leader;
  final ConfigController config;
  final String label;

  /// After a pick is stored.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final chosen = config.integrations.streamerFor(integration);
    final leads = leader != null && streamers.contains(leader);
    return DropdownButtonFormField<String>(
      // A chosen streamer that's gone shows as Leader (and stays stored).
      initialValue: chosen != null && streamers.contains(chosen)
          ? chosen
          : leaderValue,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: l.streamerPickerHelp,
        helperMaxLines: 3,
      ),
      items: [
        DropdownMenuItem(
          value: leaderValue,
          child: Text(
            leads
                ? l.streamerLeader(leader!)
                : l.streamerLeaderUnknown(streamers.first),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final s in streamers)
          DropdownMenuItem(
            value: s,
            child: Text(s, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) {
        config.update(
          (c) => c.copyWith(
            integrations: c.integrations.withStreamer(
              integration,
              value == null || value == leaderValue ? null : value,
            ),
          ),
        );
        onChanged();
      },
    );
  }
}
