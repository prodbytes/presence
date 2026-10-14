import 'dart:convert';

import 'package:http/http.dart' as http;

import 'roles_service.dart';

/// One Google account of the signed-in user's profile.
class ProfileAccount {
  const ProfileAccount({
    required this.email,
    required this.owner,
    required this.current,
  });

  factory ProfileAccount.fromJson(Map<String, Object?> json) => ProfileAccount(
    email: '${json['email'] ?? ''}',
    owner: json['owner'] == true,
    current: json['current'] == true,
  );

  final String email;

  /// Made the profile: its roles are the profile's, and it can't be unlinked.
  final bool owner;

  /// The account signed in now.
  final bool current;
}

/// A one-time code that links another account to this profile.
class LinkCode {
  const LinkCode({required this.code, required this.expiresAt});

  /// As shown and typed: `ABCD-EFGH`.
  final String code;
  final DateTime expiresAt;
}

/// A device's stream key, as the auth API made it: shown once.
class StreamKey {
  const StreamKey({
    required this.profile,
    required this.device,
    required this.key,
  });

  final String profile;
  final String device;

  /// `psk_…`: only its hash is kept.
  final String key;
}

/// What `POST /api/auth/account/delete` deleted.
class AccountDeletion {
  const AccountDeletion({
    required this.profile,
    this.wholeProfile = false,
    this.accounts = 0,
    this.objects = 0,
    this.complete = true,
  });

  factory AccountDeletion.fromJson(Map<String, Object?> json) =>
      AccountDeletion(
        profile: json['profile'] is String ? json['profile']! as String : null,
        wholeProfile: json['deleted'] == 'profile',
        accounts: (json['accounts'] as num?)?.toInt() ?? 0,
        objects: (json['objects'] as num?)?.toInt() ?? 0,
        complete: json['complete'] != false,
      );

  /// The profile it was (null: the account had none left, nothing to do).
  final String? profile;

  /// The owner's: the whole profile went, with every account linked to it.
  /// Otherwise only this account left the profile.
  final bool wholeProfile;

  /// How many accounts lost the profile (this one included).
  final int accounts;

  /// How many files of the profile's cloud folder went in this request.
  final int objects;

  /// False while the profile's folder isn't empty yet: ask again.
  final bool complete;
}

/// The auth API's profile routes: a profile is one person's cloud folder,
/// whichever of their Google accounts signs in. Failures throw
/// [RolesException] with the HTTP status (404: a wrong, used or expired
/// code; 409: the account can't be linked or unlinked; 429: throttled).
abstract class ProfileClient {
  /// The profile's accounts, the owner first.
  Future<List<ProfileAccount>> accounts(String idToken);

  /// A new code another account can use, for 10 minutes.
  Future<LinkCode> linkCode(String idToken);

  /// Moves the signed-in account into the profile of [code]; its accounts.
  Future<List<ProfileAccount>> link(String idToken, String code);

  /// Removes [email] from the profile; the accounts left.
  Future<List<ProfileAccount>> unlink(String idToken, String email);

  /// A new stream key for [device], a device of the profile to be (a
  /// Raspberry Pi running the streamer), replacing any key it had
  /// (`POST /api/auth/profile/stream-key`).
  Future<StreamKey> streamKey(String idToken, String device);

  /// Deletes the signed-in account (`POST /api/auth/account/delete`) of
  /// [profile], the profile the app shows (409 if it's another now): a
  /// linked account leaves the profile; its owner deletes the whole
  /// profile, its cloud data and every linked account's link. Asks again
  /// while the API says it isn't [AccountDeletion.complete] (a big folder),
  /// up to [rounds] times.
  Future<AccountDeletion> deleteAccount(
    String idToken,
    String profile, {
    int rounds = 20,
  });
}

/// The real client, next to `GET /api/auth` (see [HttpRolesClient]).
class HttpProfileClient implements ProfileClient {
  HttpProfileClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    String idToken, [
    String body = '',
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $idToken';
    if (method == 'POST') {
      request.headers['content-type'] = 'text/plain; charset=utf-8';
      request.bodyBytes = utf8.encode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    if (response.statusCode ~/ 100 != 2) {
      throw RolesException(response.statusCode);
    }
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  static List<ProfileAccount> _accounts(Map<String, Object?> body) {
    final accounts = body['accounts'];
    return accounts is List
        ? [
            for (final a in accounts)
              if (a is Map) ProfileAccount.fromJson(a.cast<String, Object?>()),
          ]
        : const [];
  }

  @override
  Future<List<ProfileAccount>> accounts(String idToken) async =>
      _accounts(await _send('GET', '/api/auth/profile', idToken));

  @override
  Future<LinkCode> linkCode(String idToken) async {
    final body = await _send('POST', '/api/auth/profile/link-code', idToken);
    return LinkCode(
      code: '${body['code']}',
      expiresAt:
          DateTime.tryParse('${body['expiresAt']}') ??
          DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<List<ProfileAccount>> link(String idToken, String code) async =>
      _accounts(await _send('POST', '/api/auth/profile/link', idToken, code));

  @override
  Future<StreamKey> streamKey(String idToken, String device) async {
    final body = await _send(
      'POST',
      '/api/auth/profile/stream-key',
      idToken,
      device,
    );
    return StreamKey(
      profile: '${body['profile']}',
      device: '${body['device']}',
      key: '${body['key']}',
    );
  }

  @override
  Future<AccountDeletion> deleteAccount(
    String idToken,
    String profile, {
    int rounds = 20,
  }) async {
    var objects = 0;
    for (var round = 0; ; round++) {
      final result = AccountDeletion.fromJson(
        await _send('POST', '/api/auth/account/delete', idToken, profile),
      );
      objects += result.objects;
      if (result.complete || round + 1 >= rounds) {
        return AccountDeletion(
          profile: result.profile,
          wholeProfile: result.wholeProfile,
          accounts: result.accounts,
          objects: objects,
          complete: result.complete,
        );
      }
    }
  }

  @override
  Future<List<ProfileAccount>> unlink(String idToken, String email) async =>
      _accounts(
        await _send('POST', '/api/auth/profile/unlink', idToken, email),
      );
}
