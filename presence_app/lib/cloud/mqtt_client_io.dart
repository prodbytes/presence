import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

/// An MQTT client over a WebSocket to the presigned [url] (Android, iOS,
/// desktop), on the URL's port (443 for AWS IoT's `wss://`; the local
/// stack's broker is `ws://localhost:4566`). One attempt: [LiveSync] retries with backoff, and a new URL.
MqttClient newWebSocketClient(String url, String clientId) =>
    MqttServerClient.withPort(
        url,
        clientId,
        Uri.parse(url).port,
        maxConnectionAttempts: 1,
      )
      ..useWebSocket = true
      ..secure = false;
