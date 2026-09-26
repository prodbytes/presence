import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'sigv4.dart';

/// An S3 upload that didn't succeed.
class S3Exception implements Exception {
  S3Exception(this.statusCode, this.body);

  final int statusCode;
  final String body;

  /// AWS refused the credentials (expired or revoked): get new ones.
  bool get credentialsRejected =>
      statusCode == 403 &&
      (body.contains('ExpiredToken') || body.contains('InvalidToken'));

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
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now,
       _signer = SigV4Signer(region: region);

  final String bucket;
  final String region;
  final http.Client _client;
  final DateTime Function() _now;
  final SigV4Signer _signer;

  String get host => '$bucket.s3.$region.amazonaws.com';

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
      headers: {'host': host, 'content-type': contentType},
      payloadHash: sha256.convert(bytes).toString(),
      credentials: credentials,
      now: _now(),
    );
    // Browsers set Host themselves and refuse it from scripts.
    final response = await _client.put(
      uri,
      headers: {...headers}..remove('host'),
      body: bytes,
    );
    if (response.statusCode != 200) {
      throw S3Exception(response.statusCode, response.body);
    }
  }
}
