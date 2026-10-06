import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/cloud/s3.dart';
import 'package:presence_app/cloud/sigv4.dart';

void main() {
  group('clock skew', clockSkewTests);

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

  test('recordings are streamed, with an unsigned payload and signed '
      'headers', () async {
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
    var read = false;
    Stream<List<int>> body() async* {
      read = true;
      yield [1, 2];
      yield [3];
    }

    await bucket.putStream(
      'us-east-1:id/media/c.mp4',
      body(),
      3,
      contentType: 'video/mp4',
      credentials: const AwsCredentials(
        accessKeyId: 'AKID',
        secretAccessKey: 'secret',
        sessionToken: 'token',
      ),
    );
    expect(read, isTrue);
    expect(sent.method, 'PUT');
    expect(sent.url.path, '/us-east-1:id/media/c.mp4');
    expect(sent.headers['x-amz-content-sha256'], 'UNSIGNED-PAYLOAD');
    expect(sent.headers['x-amz-storage-class'], 'INTELLIGENT_TIERING');
    expect(sent.headers['content-type'], 'video/mp4');
    expect(sent.contentLength, 3);
    expect(sent.bodyBytes, [1, 2, 3]);
    final authorization = sent.headers['authorization']!;
    expect(authorization, contains('x-amz-content-sha256'));
    expect(authorization, contains('x-amz-storage-class'));
    // Signed as AWS documents for UNSIGNED-PAYLOAD: the literal string in
    // the canonical request's payload line.
    final expected = const SigV4Signer(region: 'us-east-1').sign(
      method: 'PUT',
      uri: sent.url,
      headers: {
        'host': 'b.s3.us-east-1.amazonaws.com',
        'content-type': 'video/mp4',
        'x-amz-storage-class': 'INTELLIGENT_TIERING',
      },
      payloadHash: SigV4Signer.unsignedPayload,
      credentials: const AwsCredentials(
        accessKeyId: 'AKID',
        secretAccessKey: 'secret',
        sessionToken: 'token',
      ),
      now: DateTime.utc(2026, 9, 27),
    );
    expect(authorization, expected['authorization']);
  });

  test('a full listing page is parsed on another isolate, the same', () async {
    final xml = StringBuffer('<ListBucketResult>');
    for (var i = 0; i < 1000; i++) {
      xml.write(
        '<Contents><Key>p/events/year=2026/day=001/$i.json</Key>'
        '<LastModified>2026-10-01T00:00:00.000Z</LastModified>'
        '<ETag>&quot;e$i&quot;</ETag><Size>300</Size>'
        '<StorageClass>INTELLIGENT_TIERING</StorageClass></Contents>',
      );
    }
    xml.write('<IsTruncated>false</IsTruncated></ListBucketResult>');
    expect(xml.length, greaterThan(64 * 1024));
    final bucket = S3Bucket(
      bucket: 'b',
      region: 'us-east-1',
      client: MockClient((request) async => http.Response('$xml', 200)),
    );
    final objects = await bucket.listETags(
      'p/',
      credentials: const AwsCredentials(
        accessKeyId: 'AKID',
        secretAccessKey: 'secret',
      ),
    );
    expect(objects, hasLength(1000));
    expect(objects['p/events/year=2026/day=001/999.json'], 'e999');
    expect(S3Bucket.parseListing('$xml').$1, objects);
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

void clockSkewTests() {
  const creds = AwsCredentials(
    accessKeyId: 'AKID',
    secretAccessKey: 'secret',
    sessionToken: 'token',
  );
  const skewed =
      '<Error><Code>RequestTimeTooSkewed</Code><Message>The difference '
      'between the request time and the current time is too large.'
      '</Message><RequestTime>20260927T000000Z</RequestTime>'
      '<ServerTime>2026-09-27T00:17:30Z</ServerTime></Error>';

  test('a request signed at the wrong time corrects the clock by AWS\'s '
      'time, and the next one is signed with it', () async {
    final dates = <String>[];
    var calls = 0;
    final clock = AwsClock(now: () => DateTime.utc(2026, 9, 27));
    final bucket = S3Bucket(
      bucket: 'b',
      region: 'us-east-1',
      clock: clock,
      client: MockClient((request) async {
        dates.add(request.headers['x-amz-date']!);
        return calls++ == 0
            ? http.Response(skewed, 403)
            : http.Response('', 200);
      }),
    );
    Future<void> put() => bucket.put(
      'us-east-1:id/events/e.json',
      Uint8List.fromList([1]),
      contentType: 'application/json',
      credentials: creds,
    );
    final error = await put().then<S3Exception?>(
      (_) => null,
      onError: (Object e) => e as S3Exception,
    );
    expect(error!.clockSkewed, isTrue);
    expect(error.credentialsRejected, isFalse);
    expect(error.clockOffset, const Duration(minutes: 17, seconds: 30));
    expect(clock.offset, const Duration(minutes: 17, seconds: 30));
    await put();
    expect(dates, ['20260927T000000Z', '20260927T001730Z']);
    expect(
      AwsClock.describe(error.clockOffset!),
      contains("This device's clock is off by 18 min"),
    );
  });

  test('without a ServerTime, the Date header gives AWS\'s time', () async {
    final clock = AwsClock(now: () => DateTime.utc(2026, 9, 27, 12));
    final bucket = S3Bucket(
      bucket: 'b',
      region: 'us-east-1',
      clock: clock,
      client: MockClient(
        (request) async => http.Response(
          '<Error><Code>RequestTimeTooSkewed</Code></Error>',
          403,
          headers: {'date': 'Sun, 27 Sep 2026 11:40:00 GMT'},
        ),
      ),
    );
    await expectLater(
      bucket.get('k', credentials: creds),
      throwsA(isA<S3Exception>().having((e) => e.clockSkewed, 'skewed', true)),
    );
    expect(clock.offset, const Duration(minutes: -20));
  });

  test('HTTP dates parse; anything else is null', () {
    expect(
      S3Bucket.parseHttpDate('Tue, 06 Oct 2026 12:01:02 GMT'),
      DateTime.utc(2026, 10, 6, 12, 1, 2),
    );
    expect(S3Bucket.parseHttpDate('yesterday'), isNull);
    expect(S3Bucket.parseHttpDate('Tue, 06 Foo 2026 12:01:02 GMT'), isNull);
  });

  test('other errors leave the clock alone', () async {
    final clock = AwsClock(now: () => DateTime.utc(2026, 9, 27));
    final bucket = S3Bucket(
      bucket: 'b',
      region: 'us-east-1',
      clock: clock,
      client: MockClient(
        (request) async => http.Response(
          '<Error><Code>AccessDenied</Code></Error>',
          403,
          headers: {'date': 'Sun, 27 Sep 2026 11:40:00 GMT'},
        ),
      ),
    );
    await expectLater(
      bucket.get('k', credentials: creds),
      throwsA(isA<S3Exception>()),
    );
    expect(clock.offset, Duration.zero);
  });
}
