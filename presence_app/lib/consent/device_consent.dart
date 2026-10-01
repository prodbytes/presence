import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The recording consent given on a device (see `ConsentScreen`): whoever
/// uses the device confirms they have the right to record where it records,
/// and that faces used to recognise people are biometric data under the
/// GDPR. Asked once per device, before anything shows or records.
///
/// Saved in the `settings` store as `consent`: the device ID, the [version]
/// of the text agreed to, when, and a verification [hash] of those. On
/// launch the record must match this device's ID, the current [version]
/// and its own hash, or consent is asked again. The hash binds the record
/// to the device; it's not a secret, so it detects mix-ups and edits, not
/// a determined forger.
abstract final class DeviceConsent {
  /// Bump when the consent text changes in substance, to ask every device
  /// again. Rewording that doesn't change what's agreed to keeps it.
  static const int version = 1;

  /// The verification hash for a consent given on [deviceId] at
  /// [acceptedAt] (milliseconds since the epoch) to text [version].
  static String hash(String deviceId, int version, int acceptedAt) => sha256
      .convert(utf8.encode('presence-consent|v$version|$deviceId|$acceptedAt'))
      .toString();

  /// The record to save when consent is given on [deviceId] at [at].
  static Map<String, Object?> record(String deviceId, DateTime at) {
    final acceptedAt = at.millisecondsSinceEpoch;
    return {
      'deviceId': deviceId,
      'version': version,
      'acceptedAt': acceptedAt,
      'hash': hash(deviceId, version, acceptedAt),
    };
  }

  /// Whether [record] is a valid consent for [deviceId] to this [version].
  static bool isValid(Map<String, Object?>? record, String deviceId) {
    if (record == null) return false;
    final acceptedAt = record['acceptedAt'];
    return record['deviceId'] == deviceId &&
        record['version'] == version &&
        acceptedAt is int &&
        record['hash'] == hash(deviceId, version, acceptedAt);
  }
}
