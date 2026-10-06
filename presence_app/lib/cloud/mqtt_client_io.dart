import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// An MQTT client over a WebSocket to the presigned [url] (Android, iOS,
/// desktop). One attempt: [LiveSync] retries with backoff, and a new URL.
MqttClient newWebSocketClient(String url, String clientId) =>
    MqttServerClient.withPort(url, clientId, 443, maxConnectionAttempts: 1)
      ..useWebSocket = true
      ..secure = false;
