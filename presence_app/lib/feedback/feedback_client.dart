import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/roles_service.dart';

/// One message of a member's conversation with the administrators.
class FeedbackMessage {
  const FeedbackMessage({
    required this.fromAdmin,
    required this.message,
    required this.sentAt,
    this.by = '',
  });

  factory FeedbackMessage.fromJson(Map<String, Object?> json) =>
      FeedbackMessage(
        fromAdmin: json['from'] == 'admin',
        by: '${json['by'] ?? ''}',
        message: '${json['message'] ?? ''}',
        sentAt:
            DateTime.tryParse('${json['sentAt']}') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  /// A reply from an administrator, else the member's own message.
  final bool fromAdmin;

  /// The replying admin's email: only admins are told ([FeedbackThread]).
  final String by;
  final String message;
  final DateTime sentAt;
}

/// A member's whole conversation, as admins list it.
class FeedbackThread {
  const FeedbackThread({
    required this.email,
    required this.name,
    required this.messages,
  });

  factory FeedbackThread.fromJson(Map<String, Object?> json) => FeedbackThread(
    email: '${json['email'] ?? ''}',
    name: '${json['name'] ?? ''}',
    messages: [
      if (json['messages'] case final List list)
        for (final m in list.whereType<Map>())
          FeedbackMessage.fromJson(m.cast<String, Object?>()),
    ],
  );

  final String email;

  /// The member's Google profile name, or empty.
  final String name;

  /// Oldest first; never empty.
  final List<FeedbackMessage> messages;

  /// Whether the member wrote last: it waits for a reply.
  bool get awaitingReply => messages.isNotEmpty && !messages.last.fromAdmin;
}

/// The auth API's Feedback and Help routes: members read and add to their
/// own conversation (`/api/auth/feedback`); admins list every conversation
/// and reply. Failures throw [RolesException] with the HTTP status (409: the
/// day's limit of messages is reached; 429: throttled).
abstract class FeedbackClient {
  /// The signed-in member's conversation, oldest first.
  Future<List<FeedbackMessage>> mine(String idToken);

  /// Sends [message]; returns it as kept.
  Future<FeedbackMessage> send(String idToken, String message);

  /// Every conversation, the latest active first (admins only).
  Future<List<FeedbackThread>> threads(String idToken);

  /// Answers [email]'s conversation (admins only); returns the reply.
  Future<FeedbackMessage> reply(String idToken, String email, String message);
}

/// The real client, next to `GET /api/auth` (see [HttpRolesClient]).
class HttpFeedbackClient implements FeedbackClient {
  HttpFeedbackClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  /// The longest message the API keeps, in characters.
  static const maxMessage = 2000;

  final Uri base;
  final http.Client _client;

  Future<Map<String, Object?>> _json(Future<http.Response> request) async {
    final response = await request;
    if (response.statusCode ~/ 100 != 2) {
      throw RolesException(response.statusCode);
    }
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  Map<String, String> _auth(String idToken) => {
    'authorization': 'Bearer $idToken',
  };

  @override
  Future<List<FeedbackMessage>> mine(String idToken) async {
    final body = await _json(
      _client.get(base.resolve('/api/auth/feedback'), headers: _auth(idToken)),
    );
    return [
      if (body['messages'] case final List list)
        for (final m in list.whereType<Map>())
          FeedbackMessage.fromJson(m.cast<String, Object?>()),
    ];
  }

  @override
  Future<FeedbackMessage> send(String idToken, String message) async =>
      FeedbackMessage.fromJson(
        await _json(
          _client.post(
            base.resolve('/api/auth/feedback'),
            headers: {
              ..._auth(idToken),
              'content-type': 'text/plain; charset=utf-8',
            },
            body: utf8.encode(message),
          ),
        ),
      );

  @override
  Future<List<FeedbackThread>> threads(String idToken) async {
    final body = await _json(
      _client.get(
        base.resolve('/api/auth/feedback/threads'),
        headers: _auth(idToken),
      ),
    );
    return [
      if (body['threads'] case final List list)
        for (final t in list.whereType<Map>())
          FeedbackThread.fromJson(t.cast<String, Object?>()),
    ];
  }

  @override
  Future<FeedbackMessage> reply(
    String idToken,
    String email,
    String message,
  ) async => FeedbackMessage.fromJson(
    await _json(
      _client.post(
        base.resolve('/api/auth/feedback/reply'),
        headers: {
          ..._auth(idToken),
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: Uri(queryParameters: {'email': email, 'message': message}).query,
      ),
    ),
  );
}
