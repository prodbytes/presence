import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/cloud/s3.dart';
import 'package:presence_app/cloud/sigv4.dart';

void main() {
  test('uploads use Intelligent-Tiering, and sign the storage class', () async {
    late http.Request sent;
    final bucket = S3Bucket(
      bucket: 'b',
      region: 'us-east-1',
      now: () => DateTime.utc(2026, 9, 27),
      client: MockClient((request) async {
        sent = request;
        return http.Response('', 200);
      }),
    );
    await bucket.put(
      'us-east-1:id/clips/c.webm',
      Uint8List.fromList([1, 2, 3]),
      contentType: 'video/webm',
      credentials: const AwsCredentials(
        accessKeyId: 'AKID',
        secretAccessKey: 'secret',
        sessionToken: 'token',
      ),
    );
    expect(sent.method, 'PUT');
    expect(sent.headers['x-amz-storage-class'], 'INTELLIGENT_TIERING');
    expect(sent.headers['authorization'], contains('x-amz-storage-class'));
    expect(sent.bodyBytes, [1, 2, 3]);
  });
}
