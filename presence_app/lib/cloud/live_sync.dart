import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../config.dart';
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

  /// Publishes [payload] on [topic] (QoS 1): completes once it's sent,
  /// without waiting for the broker's acknowledgement (PUBACK).
  Future<void> publish(String topic, Uint8List payload);

  /// Disconnects.
  Future<void> close();
}

/// Opens a [LiveConnection] to the presigned WebSocket [url] as
/// [clientId]; [persistent]: with a persistent session (cleanSession off),
/// so the broker keeps QoS 1 messages for it while it's away. Throws when
/// the broker refuses it.
typedef LiveConnect = Future<LiveConnection> Function(
  String url,
  String clientId, {
  bool persistent,
});

/// Live sync's connection: [off] (no endpoint, signed out, or Never),
/// [connecting], [connected], [idle] (between scheduled connections) or
/// [error] (the last attempt failed; it retries).
enum LiveSyncState { off, connecting, connected, idle, error }

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
    this.onCopied,
  });

  final String identityId;
  final String deviceId;
  final Future<AwsCredentials> Function() credentials;
  final Future<void> Function(LiveEvent event) onEvent;

  /// Another device of the profile said it holds copies of events (a
  /// `copied` ack, [LiveSync.parseCopied]).
  final void Function(CopiedMessage message)? onCopied;
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

/// A ping or pong ([LiveSync.parsePresence]): who sent it, when (ms since
/// the epoch, by its clock), and the ping's nonce (a pong's: the ping it
/// answers, if any).
class PresenceMessage {
  const PresenceMessage({
    required this.deviceId,
    required this.sentAt,
    this.nonce,
  });

  final String deviceId;
  final int sentAt;
  final String? nonce;
}

/// A `copied` ack ([LiveSync.parseCopied]): device [deviceId] has stored
/// a full copy of the events [eventIds] (each with all its media), said at
/// [sentAt] (ms since the epoch, by its clock).
class CopiedMessage {
  const CopiedMessage({
    required this.deviceId,
    required this.sentAt,
    required this.eventIds,
  });

  final String deviceId;
  final int sentAt;
  final List<String> eventIds;
}

/// Live sync: the profile's devices tell each other about new and changed
/// events over MQTT (AWS IoT Core, over WebSockets signed with the profile's
/// Cognito credentials), so they arrive within a second instead of at the
/// next 15 s listing of the bucket. The bucket stays where events (and all
/// their media) are kept: a message carries only an event's metadata.
///
/// Topics are per profile: `presence/<stage>/<identityId>/events`, and
/// `.../requests` and `.../acks` for device presence: a [ping] on
/// requests, which each connected device answers with a pong on acks, so
/// each knows which of the profile's devices are live ([seenOf]). A device
/// that has stored a full copy of another's event says so with a `copied`
/// ack on acks ([ackCopied]), so each knows who holds each event.
///
/// How it connects is the **Connect to live sync** setting ([config]):
///
/// - [LiveMode.always]: stays connected, reconnecting with backoff, as
///   `<identityId>-<deviceId>-<session>` with a clean session: the session
///   part keeps two tabs of one browser from taking each other's
///   connection.
/// - [LiveMode.scheduled] (every minute by default): connects every
///   [LiveConfig.every] plus a random [maxJitter], with a **persistent
///   session** (cleanSession off) as `<identityId>-<deviceId>`, a client ID
///   stable per device and profile, so AWS IoT keeps the QoS 1 messages
///   that arrive while it's away (for 1 h by default, [sessionExpiry]);
///   stays until [drainQuiet] passes without a message (at most
///   [drainMax]), then disconnects ([LiveSyncState.idle]). A new event of
///   this device connects at once to send it. Two tabs of one browser
///   share the ID: AWS IoT drops the older connection when the other
///   connects, which only ends that tab's (brief) connection early; the
///   one that connects takes the queued messages, and the other gets them
///   from the bucket.
/// - [LiveMode.never]: never connects; nothing is published.
///
/// The IoT policy only lets an identity connect with IDs that start with
/// its own (`<identityId>-*`), which both forms do.
///
/// Off without an [endpoint] (local builds, tests): everything syncs
/// through the bucket as before.
class LiveSync extends ChangeNotifier {
  LiveSync({
    required this.endpoint,
    required this.region,
    this.stage = 'prod',
    this._connect,
    this._config = LiveConfig.always,
    DateTime Function()? now,
    Random? random,
    this.minRetry = const Duration(seconds: 1),
    this.maxRetry = const Duration(minutes: 2),
    this.renewBefore = const Duration(minutes: 2),
    this.drainQuiet = const Duration(seconds: 3),
    this.drainMax = const Duration(seconds: 30),
    this.maxJitter = const Duration(seconds: 10),
    this.sessionExpiry = const Duration(hours: 1),
    this.publishWait = const Duration(seconds: 20),
    this.connectTimeout = const Duration(seconds: 15),
    this.ackDelay = const Duration(seconds: 1),
    this.ackEvery = const Duration(seconds: 1),
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

  /// A scheduled connection disconnects once this passes without a
  /// message received or sent...
  final Duration drainQuiet;

  /// ...or after this long, whatever comes.
  final Duration drainMax;

  /// Scheduled connections wait their interval plus a random 0 to this
  /// (picked anew each time), so devices don't connect in step.
  final Duration maxJitter;

  /// How long AWS IoT keeps a persistent session (and its queued
  /// messages) after the device disconnects: 1 h by default. A scheduled
  /// wait never starts later than a minute before it ends ([nextWait]).
  final Duration sessionExpiry;

  /// How long a scheduled-mode publish waits for its connection.
  final Duration publishWait;

  /// How long getting credentials, and then connecting, may each take: an
  /// attempt that hangs (a stalled network) fails after it, into the usual
  /// back-off.
  final Duration connectTimeout;

  /// `copied` acks wait this long to go out, so events stored together
  /// share a message ([ackCopied])...
  final Duration ackDelay;

  /// ...and a backlog goes out one message per this.
  final Duration ackEvery;

  /// The largest message accepted or sent. AWS IoT allows 128 KB; events'
  /// metadata is a few KB.
  static const int maxMessageBytes = 64 * 1024;

  /// The message format's version.
  static const int version = 1;

  /// At most this many events wait to be sent while connecting.
  static const int maxOutbox = 100;

  bool get enabled => endpoint.isNotEmpty && _connect != null;

  /// How it connects; [LiveConfig.always] unless given (the app sets it
  /// from the setting).
  LiveConfig _config;

  /// How it connects (the **Connect to live sync** setting). A change
  /// applies at once: the connection starts over in the new mode.
  LiveConfig get config => _config;
  set config(LiveConfig value) {
    if (value == _config) return;
    _config = value;
    final link = _link;
    if (link != null) {
      _run(link);
    } else {
      notifyListeners();
    }
  }

  LiveSyncState _state = LiveSyncState.off;
  LiveSyncState get state => _state;
  String? _error;

  /// Why the last connection failed, when [state] is [LiveSyncState.error].
  String? get error => _error;

  int _sent = 0;
  int _received = 0;

  /// Events sent since the app started: handed to the connection to
  /// publish (QoS 1). Not a count of the broker's acknowledgements
  /// (PUBACK), which aren't waited for: one sent just before the
  /// connection drops may not have reached it (the bucket still has it).
  int get sent => _sent;

  /// Events received from other devices since the app started.
  int get received => _received;

  LiveLink? _link;
  LiveConnection? _connection;

  /// Bumped by [start] and [stop]: a connection loop of an older one ends.
  int _generation = 0;
  int _failures = 0;

  /// Wakes the connection loop early (to stop, to renew, or to connect
  /// for a publish).
  Completer<void>? _wake;

  /// Events received, handed over one at a time, in order.
  Future<void> _inbox = Future.value();

  /// Messages (events, pings) waiting for a scheduled connection to be
  /// sent: their topic's kind, the payload, and whether it went.
  final _outbox = <(String, Uint8List, Completer<bool>)>[];

  /// Bumped by each message received or sent: a scheduled connection
  /// stays while it moves.
  int _activity = 0;

  /// When the next scheduled connection is, while [LiveSyncState.idle].
  DateTime? _nextAt;

  /// How long until the next scheduled connection; null unless idle.
  Duration? get untilNext {
    final at = _nextAt;
    if (at == null || _state != LiveSyncState.idle) return null;
    final left = at.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// This run of the app's part of the client ID.
  late final String _session = List.generate(
    6,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
  ).join();

  /// The topic of [kind] (`events`, `requests` or `acks`) for
  /// [identityId].
  static String topicOf(String stage, String identityId, String kind) =>
      'presence/$stage/$identityId/$kind';

  /// The topics' kinds: events, pings ([requestsKind]) and pongs
  /// ([acksKind]).
  static const String eventsKind = 'events';
  static const String requestsKind = 'requests';
  static const String acksKind = 'acks';

  /// This device's client ID for [link] while always connected: unique to
  /// this run of the app.
  String clientIdOf(LiveLink link) =>
      '${link.identityId}-${link.deviceId}-$_session';

  /// This device's client ID for [link]'s scheduled connections: the same
  /// every time, so its persistent session is found again.
  static String stableClientIdOf(LiveLink link) =>
      '${link.identityId}-${link.deviceId}';

  /// Connects for [link] (and keeps reconnecting, or connecting on
  /// schedule) until [stop]. Does nothing when disabled, or already started
  /// for the same identity and device.
  void start(LiveLink link) {
    if (!enabled) return;
    final current = _link;
    if (current != null &&
        current.identityId == link.identityId &&
        current.deviceId == link.deviceId) {
      return;
    }
    _run(link);
  }

  void _run(LiveLink link) {
    stop();
    if (_seenIdentity != link.identityId) {
      _seen.clear();
      _pings.clear();
      _seenIdentity = link.identityId;
    }
    _link = link;
    final generation = ++_generation;
    _failures = 0;
    _loop(generation).ignore();
  }

  /// Disconnects (sign-out, another profile, or the app closing).
  void stop() {
    _generation++;
    _link = null;
    _nextAt = null;
    _wakeUp();
    _failOutbox();
    // A flush under way ends, failing its acks.
    _ackQueue.clear();
    _acksDone = null;
    _acking = false;
    final connection = _connection;
    _connection = null;
    connection?.close().catchError((Object _) {});
    _set(LiveSyncState.off);
  }

  void _failOutbox() {
    for (final (_, _, sent) in _outbox) {
      if (!sent.isCompleted) sent.complete(false);
    }
    _outbox.clear();
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
      final mode = _config.mode;
      if (mode == LiveMode.never) {
        // Until the setting changes (which starts over).
        _set(LiveSyncState.off);
        return;
      }
      final scheduled = mode == LiveMode.scheduled;
      _nextAt = null;
      _set(LiveSyncState.connecting);
      LiveConnection? connection;
      var renewing = false;
      try {
        final credentials = await link.credentials().timeout(
          connectTimeout,
          onTimeout: () => throw TimeoutException(
            'credentials took too long',
            connectTimeout,
          ),
        );
        if (!current()) return;
        final url = SigV4Signer(region: region, service: 'iotdevicegateway')
            .presignWebSocket(
              host: endpoint,
              credentials: credentials,
              now: _now(),
            );
        final connecting = _connect!(
          url,
          scheduled ? stableClientIdOf(link) : clientIdOf(link),
          persistent: scheduled,
        );
        connection = await connecting.timeout(
          connectTimeout,
          onTimeout: () {
            // One that connects after all is closed at once.
            connecting
                .then((c) => c.close())
                .catchError((Object _) {})
                .ignore();
            throw TimeoutException('connecting took too long', connectTimeout);
          },
        );
        if (!current()) {
          await connection.close();
          return;
        }
        _connection = connection;
        final topic = topicOf(stage, link.identityId, eventsKind);
        // Listening first: a persistent session's queued messages may come
        // before the subscription is acknowledged.
        final subscription = connection.messages.listen((m) {
          _activity++;
          _onMessage(link, m.$1, m.$2);
        });
        try {
          await connection.subscribe(topic);
        } catch (_) {
          await subscription.cancel();
          rethrow;
        }
        // Device presence: pings and pongs. Not needed for events, so one
        // refused leaves the connection up (presence just isn't known).
        for (final kind in const [requestsKind, acksKind]) {
          try {
            await connection.subscribe(topicOf(stage, link.identityId, kind));
          } catch (e) {
            debugPrint(
              'Presence: live sync could not subscribe to $kind: '
              '${redact(e)}',
            );
          }
        }
        if (!current()) {
          await subscription.cancel();
          await connection.close();
          return;
        }
        if (_failures > 0) {
          debugPrint(
            'Presence: live sync reconnected after $_failures failures',
          );
        } else if (!scheduled) {
          debugPrint('Presence: live sync connected');
        }
        _failures = 0;
        _set(LiveSyncState.connected);
        await _flushOutbox(link, connection);
        if (scheduled) {
          await _drain(connection, current);
          await subscription.cancel();
          if (_connection == connection) _connection = null;
          if (!current()) return;
          // Even if dropped (another tab took the ID): the broker keeps
          // the session either way.
          await connection.close().catchError((Object _) {});
          if (!current()) return;
          final wait = nextWait();
          _nextAt = _now().add(wait);
          _set(LiveSyncState.idle);
          // Until the next one, or a new event to send (at once if one
          // came while this one was closing).
          if (_outbox.isEmpty) await _sleep(wait);
          continue;
        }
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
        // The bucket still has them.
        _failOutbox();
        _set(LiveSyncState.error, _describe(e));
      }
      await _sleep(retryDelay);
    }
  }

  /// Stays connected while messages come (or go): until [drainQuiet]
  /// without any, at most [drainMax], or until the connection drops.
  Future<void> _drain(
    LiveConnection connection,
    bool Function() current,
  ) async {
    var over = false;
    final deadline = Timer(drainMax, () {
      over = true;
      _wakeUp();
    });
    var dropped = false;
    connection.done.then((_) {
      dropped = true;
      _wakeUp();
    }).ignore();
    try {
      while (current() && !over && !dropped) {
        final seen = _activity;
        await _sleep(drainQuiet);
        if (_activity == seen) break;
      }
    } finally {
      deadline.cancel();
    }
  }

  /// Sends what waited for this connection.
  Future<void> _flushOutbox(LiveLink link, LiveConnection connection) async {
    while (_outbox.isNotEmpty) {
      final (kind, payload, sent) = _outbox.removeAt(0);
      final ok = await _send(link, connection, payload, kind: kind);
      if (!sent.isCompleted) sent.complete(ok);
    }
  }

  /// The wait before the next scheduled connection: the interval (no
  /// later than a minute before the persistent session expires) plus a
  /// random 0 to [maxJitter], picked anew each time.
  @visibleForTesting
  Duration nextWait() {
    final cap = sessionExpiry - const Duration(minutes: 1);
    final every = _config.every;
    final base = every > cap && cap > Duration.zero ? cap : every;
    final jitter = _random.nextInt(maxJitter.inMilliseconds + 1);
    return base + Duration(milliseconds: jitter);
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
  /// out ([metadataOf]). Returns whether it was sent: not when it's too
  /// big, nor with live sync off (the bucket still has it). Always
  /// connected, not while disconnected; on a schedule, between connections
  /// it connects at once to send it (waiting up to [publishWait]).
  Future<bool> publishEvent(
    Map<String, Object?> event, {
    required String key,
    String? etag,
  }) async {
    final link = _link;
    if (link == null || !_canSend) return false;
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
    return _publish(link, eventsKind, payload);
  }

  /// Whether a message can go now ([connected]) or, on a schedule, with
  /// the next connection.
  bool get _canSend {
    final connected = _connection != null && _state == LiveSyncState.connected;
    final waits =
        _config.mode == LiveMode.scheduled &&
        // Connected too: a scheduled connection closing sends it next.
        _state != LiveSyncState.off &&
        _state != LiveSyncState.error;
    return connected || waits;
  }

  /// Sends [payload] on [link]'s [kind] topic: now when connected; on a
  /// schedule, with the next connection, which it starts at once (waiting
  /// up to [publishWait]).
  Future<bool> _publish(LiveLink link, String kind, Uint8List payload) {
    final connection = _connection;
    if (connection != null && _state == LiveSyncState.connected) {
      return _send(link, connection, payload, kind: kind);
    }
    final sent = Completer<bool>();
    _outbox.add((kind, payload, sent));
    if (_outbox.length > maxOutbox) {
      final (_, _, dropped) = _outbox.removeAt(0);
      if (!dropped.isCompleted) dropped.complete(false);
    }
    // Between scheduled connections: connect now.
    if (_state == LiveSyncState.idle) _wakeUp();
    return sent.future.timeout(publishWait, onTimeout: () => false);
  }

  Future<bool> _send(
    LiveLink link,
    LiveConnection connection,
    Uint8List payload, {
    String kind = eventsKind,
  }) async {
    try {
      await connection.publish(topicOf(stage, link.identityId, kind), payload);
      // [sent] counts events only.
      if (kind == eventsKind) _sent++;
      _activity++;
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Presence: live sync could not publish: ${redact(e)}');
      return false;
    }
  }

  void _onMessage(LiveLink link, String topic, Uint8List payload) {
    if (link != _link) return;
    if (topic == topicOf(stage, link.identityId, acksKind)) {
      if (parseCopied(payload, identityId: link.identityId) case final ack?) {
        _onCopied(link, ack);
        return;
      }
    }
    if (topic == topicOf(stage, link.identityId, requestsKind) ||
        topic == topicOf(stage, link.identityId, acksKind)) {
      _onPresence(link, topic, payload);
      return;
    }
    if (topic != topicOf(stage, link.identityId, eventsKind)) return;
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

  // Device presence ------------------------------------------------------

  /// The least time between two of this device's pings ([ping]): the All
  /// grid and the account sheet's devices ping every 30 s while they show.
  static const Duration pingEvery = Duration(seconds: 25);

  /// The least time between two of this device's pongs: pings from several
  /// devices at once get one answer (it's on the shared acks topic, so
  /// every pinger hears it).
  static const Duration answerEvery = Duration(seconds: 5);

  /// A ping older than this (by its `sentAt`; one a persistent session
  /// kept while this device was away) isn't answered: its sender has moved
  /// on. Its sender is still recorded as seen then.
  static const Duration pingFresh = Duration(minutes: 2);

  /// How long this device's pings are remembered: a pong that answers one
  /// of them proves its sender live now, whatever its clock says.
  static const Duration pingsKept = Duration(minutes: 2);

  /// The largest presence message accepted.
  static const int maxPresenceBytes = 1024;

  /// At most this many devices are remembered ([seenOf]).
  static const int maxSeen = 64;

  /// When each of the profile's other devices was last heard from over
  /// live sync (a ping or a pong), by device ID.
  final _seen = <String, DateTime>{};

  /// The identity [_seen] is about: it's cleared for another one.
  String? _seenIdentity;

  /// This device's recent pings: nonce → when sent.
  final _pings = <String, DateTime>{};
  DateTime? _lastPing;
  DateTime? _lastPong;

  /// When [deviceId] (another device of the profile) last showed it's
  /// running: it answered a ping of this device (the time the answer
  /// came), or sent a ping or answered another's (the time it sent it, no
  /// later than now). Null: not heard from since the app started.
  DateTime? seenOf(String deviceId) => _seen[deviceId];

  /// Forgets that [deviceId] was heard from (it was deleted, see
  /// `Persistence.deleteDevice`): no presence for it until it pings or
  /// answers again.
  void forget(String deviceId) {
    if (_seen.remove(deviceId) != null) notifyListeners();
  }

  /// Asks the profile's connected devices to say they're there: a `ping`
  /// on the requests topic, which each answers with a `pong` on the acks
  /// topic ([seenOf]). At most one every [pingEvery]; returns whether it
  /// was sent (not with live sync off or failing, nor while disconnected
  /// when always connected; on a schedule it connects to send it).
  Future<bool> ping() async {
    final link = _link;
    if (link == null || !_canSend) return false;
    final now = _now();
    final last = _lastPing;
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < pingEvery) {
      return false;
    }
    _lastPing = now;
    _pings.removeWhere((_, at) => now.difference(at) > pingsKept);
    final nonce = List.generate(
      16,
      (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[_random.nextInt(36)],
    ).join();
    _pings[nonce] = now;
    return _publish(
      link,
      requestsKind,
      _presencePayload(link, 'ping', nonce: nonce, now: now),
    );
  }

  Uint8List _presencePayload(
    LiveLink link,
    String kind, {
    String? nonce,
    required DateTime now,
  }) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'kind': kind,
        'deviceId': link.deviceId,
        'identityId': link.identityId,
        'sentAt': now.millisecondsSinceEpoch,
        'nonce': ?nonce,
      }),
    ),
  );

  void _onPresence(LiveLink link, String topic, Uint8List payload) {
    final isPing = topic == topicOf(stage, link.identityId, requestsKind);
    final message = parsePresence(
      payload,
      identityId: link.identityId,
      kind: isPing ? 'ping' : 'pong',
    );
    if (message == null) {
      debugPrint(
        'Presence: live sync dropped a malformed presence message '
        '(${payload.length} bytes)',
      );
      return;
    }
    // This device's own (or another tab's on it).
    if (message.deviceId == link.deviceId) return;
    final now = _now();
    final sentAt = DateTime.fromMillisecondsSinceEpoch(message.sentAt);
    // An answer to this device's recent ping is live now; anything else is
    // as old as its sender says (a persistent session may have kept it),
    // and never from the future.
    final answered =
        !isPing && message.nonce != null && _pings.containsKey(message.nonce);
    _see(message.deviceId, answered || sentAt.isAfter(now) ? now : sentAt);
    if (!isPing) return;
    final age = now.difference(sentAt);
    if (age > pingFresh) return;
    final last = _lastPong;
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < answerEvery) {
      return;
    }
    _lastPong = now;
    final connection = _connection;
    if (connection == null) return;
    _send(
      link,
      connection,
      _presencePayload(link, 'pong', nonce: message.nonce, now: now),
      kind: acksKind,
    ).ignore();
  }

  void _see(String deviceId, DateTime at) {
    final known = _seen[deviceId];
    if (known != null && !at.isAfter(known)) return;
    _seen.remove(deviceId);
    _seen[deviceId] = at;
    if (_seen.length > maxSeen) _seen.remove(_seen.keys.first);
    notifyListeners();
  }

  // Copy acks -----------------------------------------------------------

  /// The most event IDs one `copied` ack carries (fewer when they'd make it
  /// bigger than [maxPresenceBytes]).
  static const int maxAckIds = 32;

  /// At most this many event IDs wait to be acked; the oldest go first.
  static const int maxAckQueue = 1000;

  /// Event IDs waiting to be acked, oldest first.
  final _ackQueue = <String>{};

  /// Completes when the acks queued now have gone out: whether all did.
  Completer<bool>? _acksDone;
  bool _acking = false;

  /// Tells the profile's other devices that this device has stored a full
  /// copy of the events [eventIds] (with all their media): `copied` acks on
  /// the acks topic. They're batched: they wait [ackDelay], then go out as
  /// few messages as fit ([maxAckIds] IDs, at most [maxPresenceBytes]
  /// each), one per [ackEvery]. Returns whether they all went: not with
  /// live sync off or failing, nor while disconnected when always connected
  /// (on a schedule, it connects to send them).
  Future<bool> ackCopied(Iterable<String> eventIds) {
    final link = _link;
    if (link == null || !_canSend) return Future.value(false);
    for (final id in eventIds) {
      if (isSafeId(id)) _ackQueue.add(id);
    }
    while (_ackQueue.length > maxAckQueue) {
      _ackQueue.remove(_ackQueue.first);
    }
    if (_ackQueue.isEmpty) return Future.value(true);
    final done = _acksDone ??= Completer<bool>();
    if (!_acking) {
      _acking = true;
      Timer(ackDelay, () => _flushAcks(link, done));
    }
    return done.future;
  }

  Future<void> _flushAcks(LiveLink link, Completer<bool> done) async {
    var ok = true;
    try {
      while (_ackQueue.isNotEmpty && link == _link) {
        final now = _now();
        final batch = <String>[];
        for (final id in _ackQueue) {
          if (batch.length >= maxAckIds) break;
          final payload = _copiedPayload(link, [...batch, id], now);
          if (payload.length > maxPresenceBytes) break;
          batch.add(id);
        }
        _ackQueue.removeAll(batch);
        if (!await _publish(link, acksKind, _copiedPayload(link, batch, now))) {
          ok = false;
        }
        if (_ackQueue.isNotEmpty) await Future<void>.delayed(ackEvery);
      }
    } finally {
      if (identical(_acksDone, done)) {
        _acksDone = null;
        _acking = false;
      }
      done.complete(ok && link == _link);
    }
  }

  Uint8List _copiedPayload(
    LiveLink link,
    List<String> eventIds,
    DateTime now,
  ) => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'v': version,
        'kind': 'copied',
        'deviceId': link.deviceId,
        'identityId': link.identityId,
        'sentAt': now.millisecondsSinceEpoch,
        'eventIds': eventIds,
      }),
    ),
  );

  void _onCopied(LiveLink link, CopiedMessage ack) {
    // This device's own (or another tab's on it).
    if (ack.deviceId == link.deviceId) return;
    final now = _now();
    final sentAt = DateTime.fromMillisecondsSinceEpoch(ack.sentAt);
    // It's running (or was, when it sent it).
    _see(ack.deviceId, sentAt.isAfter(now) ? now : sentAt);
    try {
      link.onCopied?.call(ack);
    } catch (e) {
      debugPrint('Presence: live sync could not take an ack: ${redact(e)}');
    }
  }

  /// The `copied` ack in [payload], a message on [identityId]'s acks topic;
  /// null when it isn't one: too big ([maxPresenceBytes]), not JSON,
  /// another version, kind or identity, an unsafe device ID, no integer
  /// `sentAt`, or no event IDs, too many, or an unsafe one.
  static CopiedMessage? parseCopied(
    Uint8List payload, {
    required String identityId,
  }) {
    if (payload.length > maxPresenceBytes) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(payload));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final deviceId = decoded['deviceId'];
    final sentAt = decoded['sentAt'];
    final eventIds = decoded['eventIds'];
    if (decoded['v'] != version ||
        decoded['kind'] != 'copied' ||
        decoded['identityId'] != identityId ||
        !isSafeId(deviceId) ||
        sentAt is! int ||
        eventIds is! List ||
        eventIds.isEmpty ||
        eventIds.length > maxAckIds ||
        !eventIds.every(isSafeId)) {
      return null;
    }
    return CopiedMessage(
      deviceId: deviceId as String,
      sentAt: sentAt,
      eventIds: eventIds.cast<String>().toSet().toList(),
    );
  }

  static final RegExp _noncePattern = RegExp(r'^[A-Za-z0-9]{8,64}$');

  /// The presence message in [payload], a [kind] (`ping` or `pong`) on
  /// [identityId]'s requests or acks topic; null when it isn't one: too
  /// big, not JSON, another version, kind or identity, an unsafe device
  /// ID, no integer `sentAt`, or a bad nonce (required on a ping).
  static PresenceMessage? parsePresence(
    Uint8List payload, {
    required String identityId,
    required String kind,
  }) {
    if (payload.length > maxPresenceBytes) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(payload));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final deviceId = decoded['deviceId'];
    final sentAt = decoded['sentAt'];
    final nonce = decoded['nonce'];
    if (decoded['v'] != version ||
        decoded['kind'] != kind ||
        decoded['identityId'] != identityId ||
        !isSafeId(deviceId) ||
        sentAt is! int ||
        (nonce != null &&
            (nonce is! String || !_noncePattern.hasMatch(nonce))) ||
        (kind == 'ping' && nonce == null)) {
      return null;
    }
    return PresenceMessage(
      deviceId: deviceId as String,
      sentAt: sentAt,
      nonce: nonce as String?,
    );
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
