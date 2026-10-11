import 'package:mqtt_client/mqtt_browser_client.dart';
import 'package:mqtt_client/mqtt_client.dart';

/// An MQTT client over the browser's WebSocket to the presigned [url] (the
/// web), on the URL's port (443 for AWS IoT's `wss://`; the local stack's
/// broker is `ws://localhost:4566`). One attempt: [LiveSync] retries with backoff, and a new URL.
MqttClient newWebSocketClient(String url, String clientId) =>
    MqttBrowserClient.withPort(
      url,
      clientId,
      Uri.parse(url).port,
      maxConnectionAttempts: 1,
    );
