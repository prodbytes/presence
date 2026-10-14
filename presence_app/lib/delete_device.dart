import 'package:flutter/material.dart';

import 'events.dart';
import 'l10n/l10n.dart';

/// Deletes a device of the signed-in profile from its devices list
/// (`EventLog.removedDevices`), and with [events] every event it recorded
/// too (`Persistence.deleteDevice`), returning how many events went.
typedef DeleteDevice = Future<int> Function(
  String deviceId, {
  required bool events,
});

/// What the delete dialog chose.
enum DeviceDeletion {
  /// Off the list only: its events and videos stay.
  keepVideos,

  /// Its events (and their videos) are deleted too, on every device.
  deleteVideos,
}

/// How many of [events] are the device [deviceId]'s in [profileId]: what
/// deleting its videos hides.
int deviceEventCount(
  Iterable<AppEvent> events, {
  required String deviceId,
  required String? profileId,
}) => events
    .where((e) => e.deviceId == deviceId && e.profileId == profileId)
    .length;

/// Asks how to delete the device [deviceId] ([DeleteDeviceDialog]), and
/// deletes it so with [delete], saying so in a snack bar. Cancelled,
/// nothing.
Future<void> deleteDeviceAfterConfirming(
  BuildContext context, {
  required String deviceId,
  required int events,
  required DeleteDevice delete,
}) async {
  // Found now: the list asking may be gone once it's deleted.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l = context.l10n;
  final choice = await showDialog<DeviceDeletion>(
    context: context,
    builder: (context) =>
        DeleteDeviceDialog(deviceId: deviceId, events: events),
  );
  if (choice == null) return;
  try {
    final withEvents = choice == DeviceDeletion.deleteVideos;
    final deleted = await delete(deviceId, events: withEvents);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          withEvents
              ? l.settingsDeleteDeviceDone(deviceId, deleted)
              : l.settingsDeleteDeviceRemoved(deviceId),
        ),
      ),
    );
  } catch (e) {
    debugPrint('Presence: could not delete device $deviceId: $e');
    messenger?.showSnackBar(
      SnackBar(content: Text(l.settingsDeleteDeviceFailed(deviceId))),
    );
  }
}

/// "Delete brave_phone from your devices? It has 12 events.", what each
/// choice does, and Cancel, **Keep videos** (off the list only) and
/// **Delete videos** (error-colored: its events too). Pops the
/// [DeviceDeletion] chosen, or null.
class DeleteDeviceDialog extends StatelessWidget {
  const DeleteDeviceDialog({
    super.key,
    required this.deviceId,
    required this.events,
  });

  final String deviceId;
  final int events;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    return AlertDialog(
      key: const Key('delete-device-dialog'),
      icon: const Icon(Icons.delete_outline),
      title: Text(l.settingsDeleteDeviceTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              l.settingsDeleteDeviceMessage(deviceId, events),
              key: const Key('delete-device-message'),
            ),
            Text(
              l.settingsDeleteDeviceChoice,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      // Three buttons: they wrap onto lines of their own on a phone.
      actionsOverflowAlignment: OverflowBarAlignment.end,
      actions: [
        TextButton(
          key: const Key('delete-device-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.settingsDeleteDeviceCancel),
        ),
        OutlinedButton(
          key: const Key('delete-device-keep'),
          onPressed: () => Navigator.of(context).pop(DeviceDeletion.keepVideos),
          child: Text(l.settingsDeleteDeviceKeep),
        ),
        FilledButton(
          key: const Key('delete-device-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () =>
              Navigator.of(context).pop(DeviceDeletion.deleteVideos),
          child: Text(l.settingsDeleteDeviceConfirm),
        ),
      ],
    );
  }
}
