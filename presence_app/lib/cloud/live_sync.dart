import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'sigv4.dart';

/// One MQTT connection to AWS IoT Core: [MqttLiveConnection] in the app
/// (`live_mqtt.dart`); a fake in tests.
abstract class LiveConnection {
  /// Messages on the topics subscribed to: the topic and the payload.
  Stream<(String, Uint8List)> get messages;

  /// Completes when the connection drops (not when [close]d).
  Future<void> get done;

  /// Subscribes to [topic] (QoS 1).
  Future<void> subscribe(String topic);

  /// Publishes [payload] on [topic] (QoS 1).
  Future<void> publish(String topic, Uint8List payload);

  /// Disconnects.
  Future<void> close();
}

/// Opens a [LiveConnection] to the presigned WebSocket [url] as
/// [clientId]. Throws when the broker refuses it.
typedef LiveConnect = Future<LiveConnection> Function(
  String url,
  String clientId,
);

enum LiveSyncState { off, connecting, connected, error }

/// What [LiveSync] connects as: the profile's Cognito identity (its folder
/// in the bucket, and its topics), this device, how to get the identity's
/// credentials (fresh ones each time it connects), and where events from
/// the profile's other devices go.
class LiveLink {
  const LiveLink({
    required this.identityId,
    required this.deviceId,
    required this.credentials,
    required this.onEvent,
  });

  final String identityId;
  final String deviceId;
  final Future<AwsCredentials> Function() credentials;
  final Future<void> Function(LiveEvent event) onEvent;
}

/// An event another device of the profile published ([LiveSync.parse]):
/// the event's record, without anything inline (frames, thumbnails), and
/// who sent it.
class LiveEvent {
  const LiveEvent({
    required this.deviceId,
    required this.identityId,
    required this.event,
    this.sentAt,
    this.etag,
  });

  /// The device that published it.
  final String deviceId;
  final String identityId;

  /// The event's record, as uploaded to the bucket (its metadata only).
  final Map<String, Object?> event;

  /// When it was published (ms since the epoch).
  final int? sentAt;

  /// The ETag (MD5, hex) of the event's JSON as the sender uploaded it.
  final String? etag;
}

/// Live sync: the profile's devices tell each other about new and changed
/// events over MQTT (AWS IoT Core, over WebSockets signed with the profile's
/// Cognito credentials), so they arrive within a second instead of at the
/// next 15 s listing of the bucket. The bucket stays where events (and all
/// their media) are kept: a message carries only an event's metadata.
///
/// Topics are per profile: `presence/<stage>/<identityId>/events` (and,
/// later, `.../acks` and `.../requests`). The client ID is
/// `<identityId>-<deviceId>-<session>`: the IoT policy only lets an
/// identity connect with IDs that start with its own, and the session part
/// keeps two tabs of one browser from taking each other's connection.
///
/// Off without an [endpoint] (local builds, tests): everything syncs
/// through the bucket as before.
class LiveSync extends ChangeNotifier {
  LiveSync({
    required this.endpoint,
    required this.region,
    this.stage = 'prod',
    this._connect,
    DateTime Function()? now,
    Random? random,
    this.minRetry = const Duration(seconds: 1),
    this.maxRetry = const Duration(minutes: 2),
    this.renewBefore = const Duration(minutes: 2),
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  /// The AWS IoT data endpoint (`<id>-ats.iot.<region>.amazonaws.com`).
  final String endpoint;
  final String region;

  /// `prod` or `rc`: the topics' second level, as in the IoT policy.
  final String stage;
  final LiveConnect? _connect;
  final DateTime Function() _now;
  final Random _random;

  /// The wait before reconnecting after the first failure; it doubles
  /// with each failure in a row, up to [maxRetry].
  final Duration minRetry;
  final Duration maxRetry;

  /// How long before the credentials expire the connection is renewed
  /// (with a newly signed URL).
  final Duration renewBefore;

  /// The largest message accepted or sent. AWS IoT allows 128 KB; events'
  /// metadata is a few KB.
  static const int maxMessageBytes = 64 * 1024;

  /// The message format's version.
  static const int version = 1;

  bool get enabled => endpoint.isNotEmpty && _connect != null;

  LiveSyncState _state = LiveSyncState.off;
  LiveSyncState get state => _state;
  String? _error;

  /// Why the last connection failed, when [state] is [LiveSyncState.error].
  String? get error => _error;

  int _published = 0;
  int _received = 0;

  /// Events published since the app started.
  int get published => _published;

  /// Events received from other devices since the app started.
  int get received => _received;

  LiveLink? _link;
  LiveConnection? _connection;

  /// Bumped by [start] and [stop]: a connection loop of an older one ends.
  int _generation = 0;
  int _failures = 0;

  /// Wakes the connection loop early (to stop, or to renew).
  Completer<void>? _wake;

  /// Events received, handed over one at a time, in order.
  Future<void> _inbox = Future.value();

  /// This run of the app's part of the client ID.
  late final String _session = List.generate(
    6,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
  ).join();

  /// The topic of [kind] (`events`, and later `acks`, `requests`) for
  /// [identityId].
  static String topicOf(String stage, String identityId, String kind) =>
      'presence/$stage/$identityId/$kind';

  /// This device's client ID for [link].
  String clientIdOf(LiveLink link) =>
      '${link.identityId}-${link.deviceId}-$_session';

  /// Connects for [link] (and keeps reconnecting) until [stop]. Does
  /// nothing when disabled, or already started for the same identity and
  /// device.
  void start(LiveLink link) {
    if (!enabled) return;
    final current = _link;
    if (current != null &&
        current.identityId == link.identityId &&
        current.deviceId == link.deviceId) {
      return;
    }
    stop();
    _link = link;
    final generation = ++_generation;
    _failures = 0;
    _loop(generation).ignore();
  }

  /// Disconnects (sign-out, another profile, or the app closing).
  void stop() {
    _generation++;
    _link = null;
    _wakeUp();
    final connection = _connection;
    _connection = null;
    connection?.close().catchError((Object _) {});
    _set(LiveSyncState.off);
  }

  void _wakeUp() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Waits [delay], or until woken.
  Future<void> _sleep(Duration delay) {
    final wake = _wake = Completer<void>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    return wake.future.whenComplete(timer.cancel);
  }

  Future<void> _loop(int generation) async {
    bool current() => generation == _generation;
    while (current()) {
      final link = _link!;
      _set(LiveSyncState.connecting);
      LiveConnection? connection;
      var renewing = false;
      try {
        final credentials = await link.credentials();
        if (!current()) return;
        final url = SigV4Signer(region: region, service: 'iotdevicegateway')
            .presignWebSocket(
              host: endpoint,
              credentials: credentials,
              now: _now(),
            );
        connection = await _connect!(url, clientIdOf(link));
        if (!current()) {
          await connection.close();
          return;
        }
        _connection = connection;
        final topic = topicOf(stage, link.identityId, 'events');
        await connection.subscribe(topic);
        final subscription = connection.messages.listen(
          (m) => _onMessage(link, m.$1, m.$2),
        );
        if (!current()) {
          await subscription.cancel();
          await connection.close();
          return;
        }
        if (_failures > 0) {
          debugPrint(
            'Presence: live sync reconnected after $_failures failures',
          );
        } else {
          debugPrint('Presence: live sync connected');
        }
        _failures = 0;
        _set(LiveSyncState.connected);
        // New credentials (and a newly signed URL) before these expire.
        // Not when they're about to already: that would only loop.
        Timer? renew;
        if (credentials.expiration case final expiration?) {
          final left = expiration.difference(_now()) - renewBefore;
          if (left > Duration.zero) {
            renew = Timer(left, () {
              renewing = true;
              _wakeUp();
            });
          }
        }
        final wake = _wake = Completer<void>();
        await Future.any([connection.done, wake.future]);
        renew?.cancel();
        await subscription.cancel();
        if (_connection == connection) _connection = null;
        if (!current()) return;
        if (renewing) {
          debugPrint('Presence: live sync renewing its connection');
          await connection.close().catchError((Object _) {});
          continue;
        }
        // Dropped: reconnect soon.
        debugPrint('Presence: live sync disconnected; reconnecting');
        _failures = 1;
      } catch (e) {
        if (connection != null) {
          if (_connection == connection) _connection = null;
          await connection.close().catchError((Object _) {});
        }
        if (!current()) return;
        _failures++;
        if (_failures == 1 || _failures % 10 == 0) {
          debugPrint(
            'Presence: live sync failed ($_failures in a row, next try in '
            '${retryDelay.inSeconds} s): ${redact(e)}',
          );
        }
        _set(LiveSyncState.error, _describe(e));
      }
      await _sleep(retryDelay);
    }
  }

  /// The wait before the next connection attempt: [minRetry], doubling
  /// with each failure in a row, up to [maxRetry].
  @visibleForTesting
  Duration get retryDelay {
    if (_failures <= 0) return Duration.zero;
    final factor = 1 << min(_failures - 1, 20);
    final delay = minRetry * factor;
    return delay > maxRetry ? maxRetry : delay;
  }

  /// [e] as text, without any URL's query: a connection error may quote
  /// the presigned URL, whose query holds the session token.
  static String redact(Object e) =>
      '$e'.replaceAll(RegExp('\\?[^\\s\'"]*'), '?…');

  static String _describe(Object e) {
    final text = redact(e);
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  /// Publishes [event] (its record as uploaded to the bucket, at [key] with
  /// ETag [etag]) for the profile's other devices. Its inline media is left
  /// out ([metadataOf]). Returns whether it was sent: not while
  /// disconnected (the bucket still has it), nor when it's too big.
  Future<bool> publishEvent(
    Map<String, Object?> event, {
    required String key,
    String? etag,
  }) async {
    final link = _link;
    final connection = _connection;
    if (link == null ||
        connection == null ||
        _state != LiveSyncState.connected) {
      return false;
    }
    final payload = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': version,
          'kind': 'event',
          'deviceId': link.deviceId,
          'identityId': link.identityId,
          'sentAt': _now().millisecondsSinceEpoch,
          'key': key,
          'etag': ?etag,
          'event': metadataOf(event),
        }),
      ),
    );
    if (payload.length > maxMessageBytes) {
      debugPrint(
        'Presence: live sync not sending event ${event['id']}: '
        '${payload.length} bytes',
      );
      return false;
    }
    try {
      await connection.publish(
        topicOf(stage, link.identityId, 'events'),
        payload,
      );
      _published++;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Presence: live sync could not publish: ${redact(e)}');
      return false;
    }
  }

  void _onMessage(LiveLink link, String topic, Uint8List payload) {
    if (link != _link) return;
    if (topic != topicOf(stage, link.identityId, 'events')) return;
    final event = parse(payload, identityId: link.identityId);
    if (event == null) {
      debugPrint(
        'Presence: live sync dropped a malformed message '
        '(${payload.length} bytes)',
      );
      return;
    }
    // This device's own (or another tab's on it): already here.
    if (event.deviceId == link.deviceId) return;
    _received++;
    _inbox = _inbox.then((_) async {
      if (link != _link) return;
      try {
        await link.onEvent(event);
      } catch (e) {
        debugPrint('Presence: live sync could not take event: ${redact(e)}');
      }
    });
    notifyListeners();
  }

  /// Completes when the events received so far have been handed over (for
  /// tests).
  @visibleForTesting
  Future<void> get drained => _inbox;

  /// Fields that hold media inline (image bytes): never in a message, which
  /// carries metadata only. The media is in the bucket.
  static const Set<String> inlineFields = {
    'frames',
    'thumbnail',
    'recording',
    'bytes',
    'data',
  };

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');

  /// Whether [id] is safe as an event, clip, frame or device ID: it goes
  /// into object keys in the bucket.
  static bool isSafeId(Object? id) =>
      id is String && _idPattern.hasMatch(id) && !id.contains('..');
  static final RegExp _etagPattern = RegExp(r'^[0-9a-f]{32}$');

  /// [event] without inline media: no [inlineFields], and no value that is
  /// raw bytes (a byte array, or a list of more than 16 integers).
  static Map<String, Object?> metadataOf(Map<String, Object?> event) => {
    for (final MapEntry(:key, :value) in event.entries)
      if (!inlineFields.contains(key) && !_isBytes(value)) key: value,
  };

  static bool _isBytes(Object? value) =>
      value is Uint8List ||
      (value is List && value.length > 16 && value.every((v) => v is int));

  /// The event in [payload], a message on [identityId]'s events topic; null
  /// when it isn't one: too big, not JSON, another version, another
  /// identity's, or without an event ID and time. Inline media is dropped
  /// ([metadataOf]).
  static LiveEvent? parse(Uint8List payload, {required String identityId}) {
    if (payload.length > maxMessageBytes) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(payload));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final message = decoded.cast<String, Object?>();
    final deviceId = message['deviceId'];
    final event = message['event'];
    final etag = message['etag'];
    final sentAt = message['sentAt'];
    if (message['v'] != version ||
        message['kind'] != 'event' ||
        message['identityId'] != identityId ||
        deviceId is! String ||
        !isSafeId(deviceId) ||
        event is! Map ||
        (etag != null && (etag is! String || !_etagPattern.hasMatch(etag))) ||
        (sentAt != null && sentAt is! int)) {
      return null;
    }
    final record = metadataOf(event.cast<String, Object?>());
    final id = record['id'];
    final type = record['type'];
    final clipId = record['clipId'];
    if (id is! String ||
        !isSafeId(id) ||
        (clipId != null && !isSafeId(clipId)) ||
        record['time'] is! int ||
        (type != null && (type is! String || type.length > 64))) {
      return null;
    }
    return LiveEvent(
      deviceId: deviceId,
      identityId: identityId,
      event: record,
      sentAt: sentAt as int?,
      etag: etag as String?,
    );
  }

  void _set(LiveSyncState state, [String? error]) {
    if (state == _state && error == _error) return;
    _state = state;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
