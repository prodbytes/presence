import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';

/// An MQTT client over the browser's WebSocket to the presigned [url] (the
/// web). One attempt: [LiveSync] retries with backoff, and a new URL.
MqttClient newWebSocketClient(String url, String clientId) =>
    MqttBrowserClient.withPort(url, clientId, 443, maxConnectionAttempts: 1);
