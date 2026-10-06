import 'dart:async';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';

import 'live_sync.dart';
import 'mqtt_client_io.dart'
    if (dart.library.js_interop) 'mqtt_client_web.dart';

/// A [LiveConnection] to AWS IoT Core: MQTT 3.1.1 over a WebSocket to a
/// presigned URL (the `mqtt_client` package: `MqttServerClient` off the
/// web, `MqttBrowserClient` on it).
class MqttLiveConnection implements LiveConnection {
  MqttLiveConnection._(this._client);

  /// Connects to the presigned [url] as [clientId], with a clean session,
  /// or a [persistent] one (AWS IoT then keeps the QoS 1 messages of its
  /// subscriptions while it's away, 1 h by default, and sends them when it
  /// connects again); throws when the broker refuses (bad signature, or a
  /// client ID the IoT policy doesn't allow).
  static Future<LiveConnection> connect(
    String url,
    String clientId, {
    bool persistent = false,
  }) async {
    final message = MqttConnectMessage().withClientIdentifier(clientId);
    final client = newWebSocketClient(url, clientId)
      ..setProtocolV311()
      ..logging(on: false)
      ..keepAlivePeriod = 60
      ..autoReconnect = false
      ..websocketProtocols = MqttClientConstants.protocolsSingleDefault
      ..connectionMessage = persistent ? message : message.startClean();
    final connection = MqttLiveConnection._(client);
    client.onDisconnected = connection._onDisconnected;
    try {
      final status = await client.connect();
      if (status?.state != MqttConnectionState.connected) {
        throw StateError('refused (${status?.returnCode})');
      }
    } catch (_) {
      client.disconnect();
      rethrow;
    }
    connection._listen();
    return connection;
  }

  final MqttClient _client;

  /// Not broadcast: messages are kept until listened to (a persistent
  /// session's queued ones may come at once).
  final _messages = StreamController<(String, Uint8List)>();
  final _done = Completer<void>();
  bool _closing = false;
  StreamSubscription<Object?>? _updates;

  void _listen() {
    _updates = _client.updates?.listen((batch) {
      for (final received in batch) {
        final message = received.payload;
        if (message is! MqttPublishMessage) continue;
        _messages.add((
          received.topic,
          Uint8List.fromList(message.payload.message),
        ));
      }
    });
  }

  void _onDisconnected() {
    if (!_done.isCompleted && !_closing) _done.complete();
  }

  @override
  Stream<(String, Uint8List)> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> subscribe(String topic) {
    final acked = Completer<void>();
    _client
      ..onSubscribed = (t) {
        if (t == topic && !acked.isCompleted) acked.complete();
      }
      ..onSubscribeFail = (t) {
        if (t == topic && !acked.isCompleted) {
          acked.completeError(StateError('subscription refused'));
        }
      };
    if (_client.subscribe(topic, MqttQos.atLeastOnce) == null) {
      throw StateError('could not subscribe');
    }
    return acked.future.timeout(const Duration(seconds: 10));
  }

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    final builder = MqttClientPayloadBuilder();
    for (final byte in payload) {
      builder.addByte(byte);
    }
    _client.publishMessage(topic, MqttQos.atLeastOnce, builder.payload!);
  }

  @override
  Future<void> close() async {
    _closing = true;
    await _updates?.cancel();
    _client.disconnect();
    // Not awaited: it only completes once listened to.
    _messages.close().ignore();
  }
}
