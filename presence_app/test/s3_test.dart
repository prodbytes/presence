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
      'us-east-1:id/media/c.webm',
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

  test('lists keys with their ETags, across pages', () async {
    final pages = [
      '<ListBucketResult><IsTruncated>true</IsTruncated>'
          '<Contents><Key>p/events/a.json</Key>'
          '<LastModified>2026-10-01T00:00:00.000Z</LastModified>'
          '<ETag>&quot;0cc175b9c0f1b6a831c399e269772661&quot;</ETag>'
          '</Contents>'
          '<NextContinuationToken>next</NextContinuationToken>'
          '</ListBucketResult>',
      '<ListBucketResult><IsTruncated>false</IsTruncated>'
          '<Contents><Key>p/events/b&amp;c.json</Key>'
          '<ETag>"92eb5ffee6ae2fec3ad71c777531578f"</ETag></Contents>'
          '</ListBucketResult>',
    ];
    final tokens = <String?>[];
    final bucket = S3Bucket(
      bucket: 'b',
      region: 'us-east-1',
      now: () => DateTime.utc(2026, 9, 27),
      client: MockClient((request) async {
        tokens.add(request.url.queryParameters['continuation-token']);
        return http.Response(pages[tokens.length - 1], 200);
      }),
    );
    const credentials = AwsCredentials(
      accessKeyId: 'AKID',
      secretAccessKey: 'secret',
      sessionToken: 'token',
    );
    expect(await bucket.listETags('p/events/', credentials: credentials), {
      'p/events/a.json': '0cc175b9c0f1b6a831c399e269772661',
      'p/events/b&c.json': '92eb5ffee6ae2fec3ad71c777531578f',
    });
    expect(tokens, [null, 'next']);
  });
}
