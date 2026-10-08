import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'sigv4.dart';

/// An S3 upload that didn't succeed.
class S3Exception implements Exception {
  S3Exception(this.statusCode, this.body, {this.clockOffset});

  final int statusCode;
  final String body;

  /// For a request refused as signed at the wrong time
  /// ([clockSkewed]): how far AWS's time is from the device's, when the
  /// answer said (the clock is corrected by it, [AwsClock.correct]).
  final Duration? clockOffset;

  /// AWS refused the credentials (expired or revoked): get new ones.
  /// Also AccessDenied: credentials issued before the profile became
  /// premium (or before the bucket required the tier tag) lack the tag the
  /// bucket asks for; new ones have it. A pass renews them once.
  bool get credentialsRejected =>
      statusCode == 403 &&
      (body.contains('ExpiredToken') ||
          body.contains('InvalidToken') ||
          body.contains('AccessDenied'));

  /// AWS refused the request as signed too far from its time (more than
  /// 15 min): the device's clock is off.
  bool get clockSkewed =>
      statusCode == 403 && body.contains('RequestTimeTooSkewed');

  @override
  String toString() => 'S3 HTTP $statusCode: $body';
}

/// Signed uploads to one bucket (virtual-hosted-style URLs).
class S3Bucket {
  S3Bucket({
    required this.bucket,
    required this.region,
    http.Client? client,
    DateTime Function()? now,
    AwsClock? clock,
  }) : _client = client ?? http.Client(),
       clock = clock ?? (now == null ? AwsClock.shared : AwsClock(now: now)),
       _signer = SigV4Signer(region: region);

  final String bucket;
  final String region;
  final http.Client _client;

  /// The time requests are signed with; corrected when AWS says it's off.
  final AwsClock clock;
  final SigV4Signer _signer;

  String get host => '$bucket.s3.$region.amazonaws.com';

  /// Downloads [key].
  Future<Uint8List> get(
    String key, {
    required AwsCredentials credentials,
  }) async {
    final response = await _send('GET', Uri.https(host, '/$key'), credentials);
    return response.bodyBytes;
  }

  /// Every key under [prefix] (ListObjectsV2, following continuation tokens).
  Future<List<String>> list(
    String prefix, {
    required AwsCredentials credentials,
  }) async => (await listETags(prefix, credentials: credentials)).keys.toList();

  /// Every key under [prefix] with its ETag, unquoted: for a single PUT to
  /// this bucket (SSE-S3), the MD5 of the object's bytes, in hex.
  Future<Map<String, String>> listETags(
    String prefix, {
    required AwsCredentials credentials,
  }) async {
    final objects = <String, String>{};
    String? token;
    do {
      final response = await _send(
        'GET',
        Uri.https(host, '/', {
          'list-type': '2',
          'prefix': prefix,
          'continuation-token': ?token,
        }),
        credentials,
      );
      final xml = response.body;
      // A full page (up to 1000 keys, ~300 KB) is parsed on another
      // isolate, so the UI doesn't stall on it; small ones here.
      final (page, next) = xml.length > _parseInBackgroundOver
          ? await compute(parseListing, xml)
          : parseListing(xml);
      objects.addAll(page);
      token = next;
    } while (token != null);
    return objects;
  }

  /// Listings longer than this (characters) are parsed off the UI isolate.
  static const int _parseInBackgroundOver = 64 * 1024;

  /// One ListObjectsV2 page: each key with its ETag (unquoted), and the
  /// continuation token if the listing goes on.
  @visibleForTesting
  static (Map<String, String>, String?) parseListing(String xml) {
    final objects = <String, String>{};
    final keyOf = RegExp(r'<Key>([^<]*)</Key>');
    final etagOf = RegExp(r'<ETag>([^<]*)</ETag>');
    for (final m in RegExp(
      r'<Contents>(.*?)</Contents>',
      dotAll: true,
    ).allMatches(xml)) {
      final contents = m[1]!;
      final key = keyOf.firstMatch(contents)?[1];
      if (key == null) continue;
      final etag = etagOf.firstMatch(contents)?[1];
      objects[_unescape(key)] = _unescape(etag ?? '').replaceAll('"', '');
    }
    final next = RegExp(
      r'<NextContinuationToken>([^<]*)</NextContinuationToken>',
    ).firstMatch(xml);
    return (
      objects,
      xml.contains('<IsTruncated>true</IsTruncated>') ? next?.group(1) : null,
    );
  }

  Future<http.Response> _send(
    String method,
    Uri uri,
    AwsCredentials credentials,
  ) async {
    final headers = _signer.sign(
      method: method,
      uri: uri,
      headers: {'host': host},
      payloadHash: SigV4Signer.emptyPayloadHash,
      credentials: credentials,
      now: clock.now(),
    );
    final response = await _client.get(
      uri,
      headers: {...headers}..remove('host'),
    );
    _check(response);
    return response;
  }

  /// Throws an [S3Exception] for an answer that isn't a success. One that
  /// says the request was signed at the wrong time corrects [clock] by
  /// AWS's time in it (its `ServerTime`, or else its `Date` header), so
  /// the next request is signed right.
  void _check(http.Response response) {
    if (response.statusCode == 200) return;
    final error = S3Exception(response.statusCode, response.body);
    if (!error.clockSkewed) throw error;
    final serverTime =
        _serverTimeOf(response.body) ??
        parseHttpDate(response.headers['date'] ?? '');
    if (serverTime == null) throw error;
    clock.correct(serverTime);
    debugPrint(
      'Presence: AWS says the clock is off by ${clock.offset.inSeconds} s; '
      'signing with its time from now on',
    );
    throw S3Exception(
      response.statusCode,
      response.body,
      clockOffset: clock.offset,
    );
  }

  static DateTime? _serverTimeOf(String body) {
    final m = RegExp(r'<ServerTime>([^<]+)</ServerTime>').firstMatch(body);
    return m == null ? null : DateTime.tryParse(m[1]!.trim());
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// An HTTP `Date` header (`Tue, 06 Oct 2026 12:00:00 GMT`), in UTC;
  /// null when it isn't one.
  @visibleForTesting
  static DateTime? parseHttpDate(String value) {
    final m = RegExp(
      r'(\d{1,2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT',
    ).firstMatch(value);
    if (m == null) return null;
    final month = _months.indexOf(m[2]!) + 1;
    if (month == 0) return null;
    return DateTime.utc(
      int.parse(m[3]!),
      month,
      int.parse(m[1]!),
      int.parse(m[4]!),
      int.parse(m[5]!),
      int.parse(m[6]!),
    );
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// The storage class uploads use: S3 Intelligent-Tiering, which moves
  /// recordings nobody watches to cheaper tiers by itself (see
  /// presence_infra/user-data.yaml).
  static const String storageClass = 'INTELLIGENT_TIERING';

  /// Uploads [bytes] to [key].
  Future<void> put(
    String key,
    Uint8List bytes, {
    required String contentType,
    required AwsCredentials credentials,
  }) async {
    final uri = Uri.https(host, '/$key');
    final headers = _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: {
        'host': host,
        'content-type': contentType,
        'x-amz-storage-class': storageClass,
      },
      payloadHash: sha256.convert(bytes).toString(),
      credentials: credentials,
      now: clock.now(),
    );
    // Browsers set Host themselves and refuse it from scripts.
    final response = await _client.put(
      uri,
      headers: {...headers}..remove('host'),
      body: bytes,
    );
    _check(response);
  }

  /// Uploads [length] bytes from [body] to [key], as they're read: for
  /// recordings, which aren't held in memory whole nor hashed first. The
  /// payload is unsigned (`UNSIGNED-PAYLOAD`), which S3 allows over HTTPS;
  /// the headers, storage class included, are still signed.
  Future<void> putStream(
    String key,
    Stream<List<int>> body,
    int length, {
    required String contentType,
    required AwsCredentials credentials,
  }) async {
    final uri = Uri.https(host, '/$key');
    final headers = _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: {
        'host': host,
        'content-type': contentType,
        'x-amz-storage-class': storageClass,
      },
      payloadHash: SigV4Signer.unsignedPayload,
      credentials: credentials,
      now: clock.now(),
    );
    final request = _BodyRequest('PUT', uri, body)
      ..contentLength = length
      ..headers.addAll({...headers}..remove('host'));
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    _check(response);
  }
}

/// A request whose body is [_body], listened to only when the client sends
/// it, with the network's backpressure: a connection that fails first
/// never opens the file, and nothing is read ahead into memory.
class _BodyRequest extends http.BaseRequest {
  _BodyRequest(super.method, super.url, this._body);

  final Stream<List<int>> _body;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}
