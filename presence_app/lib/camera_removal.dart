import 'package:flutter/foundation.dart';

import 'blink_settings.dart' show GetDeviceFile, PutDeviceFile;

/// The camera integrations whose cameras are devices of their own, fetched
/// by a streamer (specs/blink.md, specs/gopro.md, specs/reolink.md): by the
/// operating system their events say ([AppEvent.os]), the integration's
/// files' name (`<kind>.json`, `<kind>-status.json`).
const Map<String, String> cameraIntegrations = {
  'Blink': 'blink',
  'GoPro': 'gopro',
  'Reolink': 'reolink',
};

/// What telling the streamers to stop fetching a camera did.
enum CameraRemoval {
  /// Not a camera any streamer fetches: nothing to tell.
  none,

  /// Each streamer that fetches it was sent its integration's remove.
  sent,

  /// A camera, but a streamer that fetches it couldn't be told (its key
  /// not here yet, cloud sync off), or none could be asked: it may come
  /// back.
  notSent,
}

/// Tells the streamers that fetch the camera whose device is [deviceId] to
/// stop (specs/device-deletion.md): the integration's request,
/// `{remove: <device ID>, requestedAt}`, sealed to each of [streamers]
/// whose `<kind>-status.json` lists it, as its Settings section's Remove
/// does. The integration is the one [os] (its events') names; with no
/// [os] known, every integration's status is looked in, and only a camera
/// found is told about ([CameraRemoval.none] otherwise).
Future<CameraRemoval> removeCamera(
  String deviceId, {
  required String? os,
  required List<String> streamers,
  required PutDeviceFile putFile,
  required GetDeviceFile getFile,
  required DateTime now,
}) async {
  final known = cameraIntegrations[os];
  if (os != null && known == null) return CameraRemoval.none;
  final kinds = known != null ? [known] : cameraIntegrations.values.toList();
  var found = false, answered = false, allSent = true;
  for (final kind in kinds) {
    for (final streamer in streamers) {
      if (streamer == deviceId) continue;
      final status = await _get(getFile, streamer, '$kind-status.json');
      if (status == null) continue;
      answered = true;
      final cameras = status['cameras'];
      final listed =
          cameras is List &&
          cameras.any((c) => c is Map && c['deviceId'] == deviceId);
      if (!listed) continue;
      found = true;
      final sent = await _put(putFile, streamer, '$kind.json', {
        'remove': deviceId,
        'requestedAt': now.millisecondsSinceEpoch,
      });
      if (!sent) allSent = false;
    }
  }
  if (found) return allSent ? CameraRemoval.sent : CameraRemoval.notSent;
  // A camera's device no streamer could be asked about: it may still be
  // fetched. One no streamer that answered lists isn't (any more).
  return known != null && !answered
      ? CameraRemoval.notSent
      : CameraRemoval.none;
}

Future<Map<String, Object?>?> _get(
  GetDeviceFile getFile,
  String streamer,
  String name,
) async {
  try {
    return await getFile(streamer, name);
  } catch (e) {
    debugPrint('Presence: devices/$streamer/$name: $e');
    return null;
  }
}

Future<bool> _put(
  PutDeviceFile putFile,
  String streamer,
  String name,
  Map<String, Object?> json,
) async {
  try {
    return await putFile(streamer, name, json);
  } catch (e) {
    debugPrint('Presence: devices/$streamer/$name not sent: $e');
    return false;
  }
}
