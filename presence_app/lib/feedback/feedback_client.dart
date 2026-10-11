import '../auth/auth_service.dart';
import '../auth/roles_service.dart';
import '../cloud/cloud_backend.dart';
import '../cloud/cloud_config.dart';
import '../cloud/dynamodb.dart';

/// One message of a member's conversation with the administrators.
class FeedbackMessage {
  const FeedbackMessage({
    required this.fromAdmin,
    required this.message,
    required this.sentAt,
    this.by = '',
  });

  /// A message as stored (`DynamoDb.plain`): `sentAt` in epoch ms,
  /// `fromAdmin` on a reply.
  factory FeedbackMessage.fromItem(Map<String, Object?> item) =>
      FeedbackMessage(
        fromAdmin: item['fromAdmin'] == true,
        by: '${item['by'] ?? ''}',
        message: '${item['message'] ?? ''}',
        sentAt: DateTime.fromMillisecondsSinceEpoch(
          (item['sentAt'] as num?)?.toInt() ?? 0,
          isUtc: true,
        ),
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
    required this.conversation,
    required this.email,
    required this.name,
    required this.messages,
  });

  /// Its key: the profile's identity ID (one conversation per profile).
  final String conversation;

  /// The member's email, as their app gave it (the last one that wrote).
  final String email;

  /// The member's Google profile name, or empty.
  final String name;

  /// Oldest first; never empty.
  final List<FeedbackMessage> messages;

  /// Whether the member wrote last: it waits for a reply.
  bool get awaitingReply => messages.isNotEmpty && !messages.last.fromAdmin;
}

/// Feedback and Help, straight from the app to DynamoDB with the profile's
/// AWS credentials (`POST /api/auth/credentials`, Cognito): members read and
/// add to their own conversation, one per profile, keyed by its identity
/// ID; admins (their credentials carry the admin tag) list every
/// conversation and reply. IAM keeps each to that (presence_infra/
/// identity.yaml). Failures throw [RolesException] with an HTTP-like status
/// (403: not allowed; 409: the day's limit of messages is reached; 429:
/// throttled; 503: no table or credentials).
abstract class FeedbackClient {
  /// The longest message kept, in characters.
  static const maxMessage = 2000;

  /// The most messages a member sends a day (checked by the app).
  static const dailyLimit = 20;

  /// The signed-in member's conversation, oldest first.
  Future<List<FeedbackMessage>> mine(String idToken);

  /// Sends [message]; returns it as kept.
  Future<FeedbackMessage> send(String idToken, String message);

  /// Every conversation, the latest active first (admins only).
  Future<List<FeedbackThread>> threads(String idToken);

  /// Answers the [conversation] (admins only); returns the reply.
  Future<FeedbackMessage> reply(
    String idToken,
    String conversation,
    String message,
  );
}

/// The real client: DynamoDB's `Query`, `Scan` and `PutItem` on
/// [table] (`FEEDBACK_TABLE`, from the presence-user-data stack).
class DynamoFeedbackClient implements FeedbackClient {
  DynamoFeedbackClient({
    required this.backend,
    required this.table,
    required this.user,
    DynamoDb? db,
    DateTime Function()? now,
  }) : _db = db ?? DynamoDb(region: CloudConfig.region),
       _now = now ?? DateTime.now;

  /// The profile's AWS credentials; null without cloud settings (503).
  final CloudBackend? backend;
  final String table;

  /// Who's signed in: their email and name go with their messages.
  final AuthUser? Function() user;
  final DynamoDb _db;
  final DateTime Function() _now;

  /// What a member may read: never the replying admin's email (`by`).
  static const _memberAttributes = [
    'conversation',
    'sentAt',
    'message',
    'email',
    'name',
    'fromAdmin',
  ];

  Future<CloudSession> _session(String idToken) async {
    final backend = this.backend;
    if (table.isEmpty || backend == null) throw RolesException(503);
    try {
      final session = await backend.connect(idToken);
      if (session.credentials == null) throw RolesException(503);
      return session;
    } on RolesException {
      rethrow;
    } catch (_) {
      throw RolesException(503);
    }
  }

  Future<Map<String, Object?>> _call(
    CloudSession session,
    String operation,
    Map<String, Object?> request,
  ) async {
    try {
      return await _db.call(operation, {
        'TableName': table,
        ...request,
      }, credentials: session.credentials!);
    } on DynamoDbException catch (e) {
      throw RolesException(
        e.accessDenied
            ? 403
            : e.throttled
            ? 429
            : e.conditionFailed
            ? 409
            : 502,
      );
    }
  }

  /// Every page of a `Query` or `Scan`.
  Future<List<Map<String, Object?>>> _all(
    CloudSession session,
    String operation,
    Map<String, Object?> request,
  ) async {
    final items = <Map<String, Object?>>[];
    Object? start;
    do {
      final page = await _call(session, operation, {
        ...request,
        'ExclusiveStartKey': ?start,
      });
      if (page['Items'] case final List list) {
        items.addAll(list.map(DynamoDb.plain));
      }
      start = page['LastEvaluatedKey'];
    } while (start != null);
    return items;
  }

  List<FeedbackMessage> _sorted(Iterable<Map<String, Object?>> items) =>
      [for (final item in items) FeedbackMessage.fromItem(item)]
        ..sort((a, b) => a.sentAt.compareTo(b.sentAt));

  @override
  Future<List<FeedbackMessage>> mine(String idToken) async {
    final session = await _session(idToken);
    return _sorted(await _queryMine(session));
  }

  Future<List<Map<String, Object?>>> _queryMine(CloudSession session) =>
      _all(session, 'Query', {
        'KeyConditionExpression': '#c = :c',
        'Select': 'SPECIFIC_ATTRIBUTES',
        'ProjectionExpression': [
          for (var i = 0; i < _memberAttributes.length; i++) '#a$i',
        ].join(', '),
        'ExpressionAttributeNames': {
          '#c': 'conversation',
          for (var i = 0; i < _memberAttributes.length; i++)
            '#a$i': _memberAttributes[i],
        },
        'ExpressionAttributeValues': {':c': DynamoDb.attribute(session.prefix)},
      });

  /// [message], trimmed; 400 when it's blank or too long.
  static String _checked(String message) {
    final text = message.trim();
    if (text.isEmpty || text.length > FeedbackClient.maxMessage) {
      throw RolesException(400);
    }
    return text;
  }

  /// Puts [item] at a time that's free: two messages in the same
  /// millisecond don't overwrite each other.
  Future<int> _put(CloudSession session, Map<String, Object> item) async {
    var at = _now().millisecondsSinceEpoch;
    for (var attempt = 0; ; attempt++) {
      try {
        await _call(session, 'PutItem', {
          'Item': {
            for (final MapEntry(:key, :value) in {
              ...item,
              'sentAt': at,
            }.entries)
              key: DynamoDb.attribute(value),
          },
          'ConditionExpression': 'attribute_not_exists(sentAt)',
        });
        return at;
      } on RolesException catch (e) {
        if (e.statusCode != 409 || attempt >= 2) rethrow;
        at++;
      }
    }
  }

  @override
  Future<FeedbackMessage> send(String idToken, String message) async {
    final text = _checked(message);
    final session = await _session(idToken);
    // The day's limit, as the app counts it (advisory: IAM can't).
    final since = _now().subtract(const Duration(days: 1));
    final today = _sorted(await _queryMine(session))
        .where((m) => !m.fromAdmin && m.sentAt.isAfter(since))
        .length;
    if (today >= FeedbackClient.dailyLimit) throw RolesException(409);
    final who = user();
    final at = await _put(session, {
      'conversation': session.prefix,
      'message': text,
      if (who != null && who.email.isNotEmpty) 'email': who.email,
      if (who?.name case final name? when name.trim().isNotEmpty)
        'name': name.split('\n').first.trim(),
    });
    return FeedbackMessage(
      fromAdmin: false,
      message: text,
      sentAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }

  @override
  Future<List<FeedbackThread>> threads(String idToken) async {
    final session = await _session(idToken);
    final byConversation = <String, List<Map<String, Object?>>>{};
    for (final item in await _all(session, 'Scan', const {})) {
      if (item['conversation'] case final String c) {
        (byConversation[c] ??= []).add(item);
      }
    }
    final threads = [
      for (final MapEntry(:key, :value) in byConversation.entries)
        _thread(key, value),
    ];
    threads.sort(
      (a, b) => b.messages.last.sentAt.compareTo(a.messages.last.sentAt),
    );
    return threads;
  }

  FeedbackThread _thread(
    String conversation,
    List<Map<String, Object?>> items,
  ) {
    final messages = _sorted(items);
    // The member's latest own message names them.
    final own =
        [
          for (final item in items)
            if (item['fromAdmin'] != true) item,
        ]..sort(
          (a, b) => ((b['sentAt'] as num?) ?? 0).compareTo(
            (a['sentAt'] as num?) ?? 0,
          ),
        );
    final latest = own.firstOrNull ?? const <String, Object?>{};
    return FeedbackThread(
      conversation: conversation,
      email: '${latest['email'] ?? ''}',
      name: '${latest['name'] ?? ''}',
      messages: messages,
    );
  }

  @override
  Future<FeedbackMessage> reply(
    String idToken,
    String conversation,
    String message,
  ) async {
    final text = _checked(message);
    final session = await _session(idToken);
    final by = user()?.email ?? '';
    final at = await _put(session, {
      'conversation': conversation,
      'message': text,
      'fromAdmin': true,
      if (by.isNotEmpty) 'by': by,
    });
    return FeedbackMessage(
      fromAdmin: true,
      by: by,
      message: text,
      sentAt: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
    );
  }
}
