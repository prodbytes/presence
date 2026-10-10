import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'sigv4.dart';

/// A DynamoDB call that didn't succeed: the HTTP status and DynamoDB's error
/// type (`AccessDeniedException`, `ConditionalCheckFailedException`, …).
class DynamoDbException implements Exception {
  DynamoDbException(this.statusCode, this.type, this.message);

  final int statusCode;
  final String type;
  final String message;

  bool get accessDenied => type.endsWith('AccessDeniedException');
  bool get conditionFailed => type.endsWith('ConditionalCheckFailedException');
  bool get throttled =>
      type.endsWith('ThrottlingException') ||
      type.endsWith('ProvisionedThroughputExceededException');

  @override
  String toString() => 'DynamoDB HTTP $statusCode: $type $message';
}

/// DynamoDB's JSON API, signed with the profile's temporary credentials
/// (SigV4), straight from the app: no server in between. Only what the app
/// uses: [call] with an operation's name and its request.
class DynamoDb {
  DynamoDb({required this.region, http.Client? client, AwsClock? clock})
    : _client = client ?? http.Client(),
      _clock = clock ?? AwsClock.shared,
      _signer = SigV4Signer(region: region, service: 'dynamodb');

  final String region;
  final http.Client _client;
  final AwsClock _clock;
  final SigV4Signer _signer;

  String get host => 'dynamodb.$region.amazonaws.com';

  /// Calls [operation] (`Query`, `PutItem`, …) with [request]; answers the
  /// response's JSON. Throws [DynamoDbException] for an error answer.
  Future<Map<String, Object?>> call(
    String operation,
    Map<String, Object?> request, {
    required AwsCredentials credentials,
  }) async {
    final uri = Uri.https(host, '/');
    final body = utf8.encode(jsonEncode(request));
    final headers = _signer.sign(
      method: 'POST',
      uri: uri,
      headers: {
        'host': host,
        'content-type': 'application/x-amz-json-1.0',
        'x-amz-target': 'DynamoDB_20120810.$operation',
      },
      payloadHash: sha256.convert(body).toString(),
      credentials: credentials,
      now: _clock.now(),
    );
    // Browsers set Host themselves and refuse it from scripts.
    final response = await _client.post(
      uri,
      headers: {...headers}..remove('host'),
      body: body,
    );
    final Object? json;
    try {
      json = response.body.isEmpty ? const {} : jsonDecode(response.body);
    } catch (_) {
      throw DynamoDbException(response.statusCode, 'InvalidResponse', '');
    }
    final map = json is Map
        ? json.cast<String, Object?>()
        : <String, Object?>{};
    if (response.statusCode != 200) {
      throw DynamoDbException(
        response.statusCode,
        '${map['__type'] ?? 'UnknownError'}',
        '${map['message'] ?? map['Message'] ?? ''}',
      );
    }
    return map;
  }

  /// [value] as a DynamoDB attribute value: strings, numbers and booleans.
  static Map<String, Object?> attribute(Object value) => switch (value) {
    final bool b => {'BOOL': b},
    final num n => {'N': '$n'},
    _ => {'S': '$value'},
  };

  /// [item]'s attributes as plain values (strings, numbers, booleans); other
  /// types are left out.
  static Map<String, Object?> plain(Object? item) => {
    if (item is Map)
      for (final MapEntry(:key, :value) in item.entries)
        if (value is Map)
          if (value['S'] case final String s)
            '$key': s
          else if (value['N'] case final String n)
            '$key': num.tryParse(n)
          else if (value['BOOL'] case final bool b)
            '$key': b,
  };
}
