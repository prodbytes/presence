import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/cloud/sigv4.dart';

/// AWS's published examples for header-based SigV4 on S3:
/// https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
void main() {
  const credentials = AwsCredentials(
    accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
    secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
  );
  const signer = SigV4Signer(region: 'us-east-1');
  final time = DateTime.utc(2013, 5, 24);

  test('GET Object example', () {
    final headers = signer.sign(
      method: 'GET',
      uri: Uri.https('examplebucket.s3.amazonaws.com', '/test.txt'),
      headers: {'host': 'examplebucket.s3.amazonaws.com', 'range': 'bytes=0-9'},
      payloadHash: SigV4Signer.emptyPayloadHash,
      credentials: credentials,
      now: time,
    );
    expect(
      headers['authorization'],
      'AWS4-HMAC-SHA256 '
      'Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, '
      'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, '
      'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
    );
    expect(headers['x-amz-date'], '20130524T000000Z');
  });

  test(r'PUT Object example (a key with $)', () {
    final body = utf8.encode('Welcome to Amazon S3.');
    final hash = sha256.convert(body).toString();
    expect(
      hash,
      '44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072',
    );
    final headers = signer.sign(
      method: 'PUT',
      uri: Uri.https('examplebucket.s3.amazonaws.com', r'/test$file.text'),
      headers: {
        'host': 'examplebucket.s3.amazonaws.com',
        'date': 'Fri, 24 May 2013 00:00:00 GMT',
        'x-amz-storage-class': 'REDUCED_REDUNDANCY',
      },
      payloadHash: hash,
      credentials: credentials,
      now: time,
    );
    expect(
      headers['authorization'],
      'AWS4-HMAC-SHA256 '
      'Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, '
      'SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, '
      'Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd',
    );
  });

  test('session credentials sign the security token', () {
    final headers = signer.sign(
      method: 'PUT',
      uri: Uri.https('b.s3.us-east-1.amazonaws.com', '/id/clips/a.webm'),
      headers: {'host': 'b.s3.us-east-1.amazonaws.com'},
      payloadHash: SigV4Signer.emptyPayloadHash,
      credentials: const AwsCredentials(
        accessKeyId: 'ASIA',
        secretAccessKey: 'secret',
        sessionToken: 'token',
      ),
      now: time,
    );
    expect(headers['x-amz-security-token'], 'token');
    expect(headers['authorization'], contains('x-amz-security-token'));
  });

  test('paths are encoded per segment', () {
    expect(
      SigV4Signer.canonicalPath('/us-east-1:abc/events/x y.json'),
      '/us-east-1%3Aabc/events/x%20y.json',
    );
  });
}
