import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../auth/api_config.dart';

/// A link that opens Presence on another device, which then becomes a new
/// device (with its own device ID) of the same user: shown as a QR code
/// and shared from Settings.
///
/// `<app>/?from=<device ID>&user=<user code>`: the device that shared it,
/// and, when someone was signed in, a code for their account
/// ([userCode]), so the new device can check that whoever signs in there
/// is the same user. Without `user` (DEV, nobody signs in), any user is.
@immutable
class JoinLink {
  const JoinLink({required this.from, this.user});

  /// The device ID of the device that shared the link.
  final String from;

  /// [userCode] of the user who shared it, or null when nobody was signed
  /// in.
  final String? user;

  static const String fromParam = 'from';
  static const String userParam = 'user';

  /// A short code for [userId] (a Google account ID): the first 16 hex
  /// digits of a SHA-256, so the QR code doesn't carry the account's ID
  /// itself, and is enough to tell two accounts apart.
  static String userCode(String userId) => sha256
      .convert(utf8.encode('presence-join:$userId'))
      .toString()
      .substring(0, 16);

  /// Where the app is: the page's own address on web (as served, e.g.
  /// `https://presence.nu01.com/app/`), and the site's `/app/` on Android
  /// and iOS.
  static Uri get appUrl =>
      kIsWeb ? Uri.base : ApiConfig.baseUrl.resolve('app/');

  /// The link for this device ([from]) and the signed-in user ([userId],
  /// null when nobody is), on [app] ([appUrl] by default).
  static Uri build({required String from, String? userId, Uri? app}) =>
      (app ?? appUrl).removeFragment().replace(
        queryParameters: {
          fromParam: from,
          if (userId != null) userParam: userCode(userId),
        },
      );

  /// The join link in [uri], or null when it isn't one.
  static JoinLink? parse(Uri uri) {
    final params = uri.queryParameters;
    final from = params[fromParam];
    if (from == null || from.isEmpty) return null;
    final user = params[userParam];
    return JoinLink(from: from, user: user?.isEmpty ?? true ? null : user);
  }

  /// Whether [userId] (null: nobody signed in) is the user who shared it.
  bool isFor(String? userId) =>
      user == null || (userId != null && userCode(userId) == user);

  @override
  bool operator ==(Object other) =>
      other is JoinLink && other.from == from && other.user == user;

  @override
  int get hashCode => Object.hash(from, user);
}

/// Where a device opened with a [JoinLink] stands.
enum JoinStatus {
  /// Not known yet: the device ID is loading, or the launch sign-in check
  /// is running.
  waiting,

  /// Nobody is signed in: sign in, as the user who shared the link.
  signIn,

  /// Signed in as the user who shared it (or nobody signs in, in DEV):
  /// this device is one of theirs, with its own device ID.
  joined,

  /// Signed in as someone else.
  otherUser,

  /// Opened on the device that shared it: it has to be another device.
  sameDevice;

  /// Where [link] stands on this device ([deviceId]), with [userId] signed
  /// in (null: nobody), [checking] whether a session can be restored, and
  /// [dev] when nobody signs in at all.
  static JoinStatus of(
    JoinLink link, {
    required String? deviceId,
    required String? userId,
    required bool checking,
    required bool dev,
  }) {
    if (deviceId == null) return waiting;
    if (link.from == deviceId) return sameDevice;
    if (dev || link.user == null) return joined;
    if (userId == null) return checking ? waiting : signIn;
    return link.isFor(userId) ? joined : otherUser;
  }
}
