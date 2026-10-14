package presence.payments;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;

/** Outgoing HTTPS calls (Google's APIs, rbacr's grants), replaceable in tests. */
@FunctionalInterface
interface Web {

    /** How long a call may take: the app waits for the verification. */
    Duration TIMEOUT = Duration.ofSeconds(4);

    record Reply(int status, String body) {
    }

    /** Sends {@code method} to {@code uri} with {@code headers} and {@code body} (null for none). */
    Reply send(String method, URI uri, Map<String, String> headers, String body) throws Exception;

    /** The JDK's HTTP client, within {@link #TIMEOUT}; no redirects followed. */
    static Web jdk() {
        var client = HttpClient.newBuilder().connectTimeout(TIMEOUT)
                .followRedirects(HttpClient.Redirect.NEVER).build();
        return (method, uri, headers, body) -> {
            var request = HttpRequest.newBuilder(uri).timeout(TIMEOUT)
                    .method(method, body == null ? HttpRequest.BodyPublishers.noBody()
                            : HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));
            headers.forEach(request::header);
            var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            return new Reply(response.statusCode(), response.body());
        };
    }
}
