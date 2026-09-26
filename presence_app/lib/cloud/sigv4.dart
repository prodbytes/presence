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

/// AWS Signature Version 4 for S3 requests: the headers to add so AWS
/// accepts a request made with [AwsCredentials]. See
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
class SigV4Signer {
  const SigV4Signer({required this.region, this.service = 's3'});

  final String region;
  final String service;

  /// The SHA-256 of an empty body, used for requests without one.
  static final String emptyPayloadHash = sha256.convert(const []).toString();

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
