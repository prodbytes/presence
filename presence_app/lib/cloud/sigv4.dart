import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Temporary AWS credentials (from Cognito).
class AwsCredentials {
  const AwsCredentials({
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
    this.expiration,
  });

  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;
  final DateTime? expiration;

  /// Whether these expire within [margin] of [now].
  bool expiresSoon(
    DateTime now, {
    Duration margin = const Duration(minutes: 5),
  }) => expiration != null && !now.add(margin).isBefore(expiration!);
}

/// The time AWS requests are signed with, and credentials' expiry is
/// judged by: the device's clock, corrected by the offset an AWS answer
/// showed it has ([correct], after S3's `RequestTimeTooSkewed`). AWS
/// refuses requests signed more than 15 min off its time, so a device
/// whose clock is wrong would otherwise never sync.
///
/// [shared] in the app: S3, Cognito and live sync all sign with it, so a
/// correction S3 found applies to live sync's connection too.
class AwsClock {
  AwsClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The app's clock for AWS.
  static final AwsClock shared = AwsClock();

  final DateTime Function() _now;

  /// How far AWS's time is ahead of the device's (negative: behind).
  Duration offset = Duration.zero;

  /// AWS's time, as best known.
  DateTime now() => _now().add(offset);

  /// Takes [serverTime], AWS's time in an answer just received: from now
  /// on [now] is that far from the device's clock.
  void correct(DateTime serverTime) {
    offset = serverTime.toUtc().difference(_now().toUtc());
  }

  /// [offset] for people: "This device's clock is off by 17 min".
  static String describe(Duration offset) {
    final minutes = (offset.inSeconds.abs() / 60).ceil();
    return "This device's clock is off by $minutes min: "
        'set it to the right time to sync';
  }
}

/// AWS Signature Version 4 for S3 requests: the headers to add so AWS
/// accepts a request made with [AwsCredentials]. See
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
class SigV4Signer {
  const SigV4Signer({required this.region, this.service = 's3'});

  final String region;
  final String service;

  /// The SHA-256 of an empty body, used for requests without one.
  static final String emptyPayloadHash = sha256.convert(const []).toString();

  /// Stands for the payload hash when the body isn't signed: allowed by S3
  /// over HTTPS, where TLS protects the body. Lets a large upload be sent
  /// without hashing it first.
  static const String unsignedPayload = 'UNSIGNED-PAYLOAD';

  /// Signs [method] [uri] with [headers] (which must include `host`) and a
  /// body whose SHA-256 is [payloadHash]. Returns every header to send:
  /// the given ones plus `x-amz-date`, `x-amz-content-sha256`,
  /// `x-amz-security-token` (with session credentials) and `authorization`.
  Map<String, String> sign({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required String payloadHash,
    required AwsCredentials credentials,
    required DateTime now,
  }) {
    final time = now.toUtc();
    final amzDate = _amzDate(time);
    final date = amzDate.substring(0, 8);
    final all = <String, String>{
      for (final MapEntry(:key, :value) in headers.entries)
        key.toLowerCase(): value.trim(),
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
      if (credentials.sessionToken != null)
        'x-amz-security-token': credentials.sessionToken!,
    };
    final names = all.keys.toList()..sort();
    final signedHeaders = names.join(';');
    final canonicalRequest = [
      method.toUpperCase(),
      canonicalPath(uri.path),
      canonicalQuery(uri.queryParametersAll),
      for (final name in names) '$name:${all[name]}',
      '',
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$date/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    var key = _hmac(utf8.encode('AWS4${credentials.secretAccessKey}'), date);
    key = _hmac(key, region);
    key = _hmac(key, service);
    key = _hmac(key, 'aws4_request');
    final signature = Hmac(
      sha256,
      key,
    ).convert(utf8.encode(stringToSign)).toString();

    return {
      ...all,
      'authorization':
          'AWS4-HMAC-SHA256 Credential=${credentials.accessKeyId}/$scope, '
          'SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }

  /// A presigned WebSocket URL for AWS IoT Core's MQTT endpoint ([host],
  /// its `iot:Data-ATS` endpoint): `wss://<host><path>?X-Amz-...`, signed
  /// with [credentials] for this signer's [service] (`iotdevicegateway`),
  /// valid for [expires] from [now]. Only `host` is signed and the payload
  /// is empty; the session token is appended after signing, as AWS IoT
  /// requires. See
  /// https://docs.aws.amazon.com/iot/latest/developerguide/protocols.html
  String presignWebSocket({
    required String host,
    String path = '/mqtt',
    required AwsCredentials credentials,
    required DateTime now,
    Duration expires = const Duration(hours: 1),
  }) {
    final time = now.toUtc();
    final amzDate = _amzDate(time);
    final date = amzDate.substring(0, 8);
    final scope = '$date/$region/$service/aws4_request';
    final query = {
      'X-Amz-Algorithm': ['AWS4-HMAC-SHA256'],
      'X-Amz-Credential': ['${credentials.accessKeyId}/$scope'],
      'X-Amz-Date': [amzDate],
      'X-Amz-Expires': ['${expires.inSeconds}'],
      'X-Amz-SignedHeaders': ['host'],
    };
    final canonicalQueryString = canonicalQuery(query);
    final canonicalRequest = [
      'GET',
      canonicalPath(path),
      canonicalQueryString,
      'host:$host',
      '',
      'host',
      emptyPayloadHash,
    ].join('\n');
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');
    var key = _hmac(utf8.encode('AWS4${credentials.secretAccessKey}'), date);
    key = _hmac(key, region);
    key = _hmac(key, service);
    key = _hmac(key, 'aws4_request');
    final signature = Hmac(
      sha256,
      key,
    ).convert(utf8.encode(stringToSign)).toString();
    final token = credentials.sessionToken;
    return 'wss://$host$path?$canonicalQueryString'
        '&X-Amz-Signature=$signature'
        '${token == null ? '' : '&X-Amz-Security-Token=${_uriEncode(token)}'}';
  }

  /// The URI path as S3 signs it: each segment URI-encoded once.
  static String canonicalPath(String path) {
    if (path.isEmpty) return '/';
    return path
        .split('/')
        .map((s) => _uriEncode(Uri.decodeComponent(s)))
        .join('/');
  }

  static String canonicalQuery(Map<String, List<String>> query) {
    final pairs = <String>[
      for (final MapEntry(:key, :value) in query.entries)
        for (final v in value) '${_uriEncode(key)}=${_uriEncode(v)}',
    ]..sort();
    return pairs.join('&');
  }

  /// RFC 3986 encoding, as AWS requires: everything but A-Z a-z 0-9 - _ . ~
  static String _uriEncode(String value) {
    final out = StringBuffer();
    for (final byte in utf8.encode(value)) {
      final c = String.fromCharCode(byte);
      if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c)) {
        out.write(c);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  static String _amzDate(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}T'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  }
}
