import 'package:flutter/material.dart';

import 'events.dart';
import 'l10n/l10n.dart';

/// Deletes every event of a device of the signed-in profile
/// (`Persistence.deleteDevice`), returning how many went.
typedef DeleteDevice = Future<int> Function(String deviceId);

/// How many of [events] (the event log's, so none deleted) are the device
/// [deviceId]'s in [profileId]: what deleting it hides.
int deviceEventCount(
  Iterable<AppEvent> events, {
  required String deviceId,
  required String? profileId,
}) => events
    .where((e) => e.deviceId == deviceId && e.profileId == profileId)
    .length;

/// Asks whether to delete the device [deviceId], whose [events] events
/// would be hidden on every device; true when the user confirms.
Future<bool> confirmDeleteDevice(
  BuildContext context, {
  required String deviceId,
  required int events,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) =>
        DeleteDeviceDialog(deviceId: deviceId, events: events),
  );
  return confirmed ?? false;
}

/// Asks whether to delete the device [deviceId] ([confirmDeleteDevice]),
/// and if so, deletes it with [delete] and says so in a snack bar.
Future<void> deleteDeviceAfterConfirming(
  BuildContext context, {
  required String deviceId,
  required int events,
  required DeleteDevice delete,
}) async {
  // Found now: the list or cell asking may be gone once it's deleted.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l = context.l10n;
  if (!await confirmDeleteDevice(context, deviceId: deviceId, events: events)) {
    return;
  }
  try {
    final deleted = await delete(deviceId);
    messenger?.showSnackBar(
      SnackBar(content: Text(l.settingsDeleteDeviceDone(deviceId, deleted))),
    );
  } catch (e) {
    debugPrint('Presence: could not delete device $deviceId: $e');
    messenger?.showSnackBar(
      SnackBar(content: Text(l.settingsDeleteDeviceFailed(deviceId))),
    );
  }
}

/// "Delete device X? Its N events will be hidden on every device.", with
/// Cancel and Delete. Pops true for Delete.
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
              l.settingsDeleteDeviceNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('delete-device-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.settingsDeleteDeviceCancel),
        ),
        FilledButton(
          key: const Key('delete-device-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l.settingsDeleteDeviceConfirm),
        ),
      ],
    );
  }
}
