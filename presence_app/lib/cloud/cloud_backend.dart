import 'package:flutter/foundation.dart';

import 'cloud_sync.dart' show CloudSync;
import 'cognito.dart';
import 's3.dart';
import 'sigv4.dart';

/// A signed-in user's connection to their cloud storage.
abstract class CloudSession {
  /// The user's folder in the bucket (their profile's Cognito identity ID).
  String get prefix;

  /// Uploads [bytes] to [key], relative to [prefix].
  Future<void> put(String key, Uint8List bytes, String contentType);

  /// Uploads [length] bytes from [body] to [key], relative to [prefix], as
  /// they're read (a recording, without holding or hashing it whole).
  Future<void> putStream(
    String key,
    Stream<List<int>> body,
    int length,
    String contentType,
  );

  /// Every key in the user's folder that starts with [under] (all of them
  /// by default), relative to [prefix].
  Future<List<String>> list([String under = '']);

  /// Like [list], with each key's ETag: the MD5 of its bytes, in hex
  /// ([CloudSync.etagOf]), so a changed object shows without downloading it.
  Future<Map<String, String>> listETags([String under = '']);

  /// Downloads [key], relative to [prefix].
  Future<Uint8List> get(String key);

  /// Like [list], with when each object was last written (S3's time).
  Future<Map<String, DateTime>> listModified([String under = '']);

  /// Uploads [bytes] to [key] unless there's an object there already;
  /// returns whether it did.
  Future<bool> putIfNew(String key, Uint8List bytes, String contentType);

  /// Deletes [key], relative to [prefix].
  Future<void> delete(String key);

  /// The identity's temporary AWS credentials, for live sync's connection
  /// (null when there are none to share).
  AwsCredentials? get credentials;
}

/// Opens [CloudSession]s from a Google ID token. [AwsCloudBackend] in the
/// app; a fake in tests.
abstract class CloudBackend {
  Future<CloudSession> connect(String idToken);

  /// Drops cached credentials (after a sign-out, or when AWS rejects them).
  void reset();
}

/// Profile credentials (the auth API, then the Cognito identity pool) +
/// direct S3 uploads.
class AwsCloudBackend implements CloudBackend {
  AwsCloudBackend({required this._cognito, required this._bucket});

  final CognitoCredentials _cognito;
  final S3Bucket _bucket;

  @override
  Future<CloudSession> connect(String idToken) async =>
      _AwsSession(await _cognito.session(idToken), _bucket);

  @override
  void reset() => _cognito.clear();
}

class _AwsSession implements CloudSession {
  _AwsSession(this._session, this._bucket);

  final CognitoSession _session;
  final S3Bucket _bucket;

  @override
  String get prefix => _session.identityId;

  @override
  AwsCredentials get credentials => _session.credentials;

  @override
  Future<void> put(String key, Uint8List bytes, String contentType) =>
      _bucket.put(
        '$prefix/$key',
        bytes,
        contentType: contentType,
        credentials: _session.credentials,
      );

  @override
  Future<void> putStream(
    String key,
    Stream<List<int>> body,
    int length,
    String contentType,
  ) => _bucket.putStream(
    '$prefix/$key',
    body,
    length,
    contentType: contentType,
    credentials: _session.credentials,
  );

  @override
  Future<List<String>> list([String under = '']) async => [
    for (final key in await _bucket.list(
      '$prefix/$under',
      credentials: _session.credentials,
    ))
      key.substring(prefix.length + 1),
  ];

  @override
  Future<Map<String, String>> listETags([String under = '']) async => {
    for (final MapEntry(:key, :value) in (await _bucket.listETags(
      '$prefix/$under',
      credentials: _session.credentials,
    )).entries)
      key.substring(prefix.length + 1): value,
  };

  @override
  Future<Uint8List> get(String key) =>
      _bucket.get('$prefix/$key', credentials: _session.credentials);

  @override
  Future<Map<String, DateTime>> listModified([String under = '']) async => {
    for (final MapEntry(:key, :value) in (await _bucket.listModified(
      '$prefix/$under',
      credentials: _session.credentials,
    )).entries)
      key.substring(prefix.length + 1): value,
  };

  @override
  Future<bool> putIfNew(String key, Uint8List bytes, String contentType) async {
    try {
      await _bucket.put(
        '$prefix/$key',
        bytes,
        contentType: contentType,
        credentials: _session.credentials,
        onlyNew: true,
      );
      return true;
    } on S3Exception catch (e) {
      if (e.statusCode == 412) return false;
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) =>
      _bucket.delete('$prefix/$key', credentials: _session.credentials);
}
