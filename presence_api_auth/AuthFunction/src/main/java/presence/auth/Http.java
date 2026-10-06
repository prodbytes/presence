package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;

/** The HTTP side every handler shares: JSON answers, the route, the query, the body, the bearer token. */
final class Http {

    private Http() {
    }

    /** A JSON answer that nothing may cache. */
    static APIGatewayV2HTTPResponse response(int status, String json) {
        return APIGatewayV2HTTPResponse.builder()
                .withStatusCode(status)
                .withHeaders(Map.of("Content-Type", "application/json", "Cache-Control", "no-store"))
                .withBody(json)
                .build();
    }

    /** The route key ({@code "POST /api/auth/voucher"}), or empty. */
    static String route(APIGatewayV2HTTPEvent event) {
        return event == null || event.getRouteKey() == null ? "" : event.getRouteKey();
    }

    /** The query parameter {@code name}, or null. */
    static String query(APIGatewayV2HTTPEvent event, String name) {
        var parameters = event == null ? null : event.getQueryStringParameters();
        return parameters == null ? null : parameters.get(name);
    }

    /**
     * The body as text, trimmed; null if it's longer than {@code max}
     * characters.
     */
    static String bodyText(APIGatewayV2HTTPEvent event, int max) {
        var body = event == null ? null : event.getBody();
        if (body == null) {
            return "";
        }
        // Base64 and UTF-8 never shrink below a quarter of the text; skip decoding floods.
        if (body.length() > 8L * max) {
            return null;
        }
        if (event.getIsBase64Encoded()) {
            try {
                body = new String(Base64.getDecoder().decode(body), StandardCharsets.UTF_8);
            } catch (IllegalArgumentException e) {
                return "";
            }
        }
        body = body.strip();
        return body.length() > max ? null : body;
    }

    /** The token from {@code Authorization: Bearer <token>} (verified by the authorizer). */
    static String bearer(APIGatewayV2HTTPEvent event) {
        Map<String, String> headers = event == null || event.getHeaders() == null ? Map.of() : event.getHeaders();
        var value = headers.getOrDefault("authorization", headers.getOrDefault("Authorization", ""));
        return value.regionMatches(true, 0, "Bearer ", 0, 7) ? value.substring(7).strip() : value.strip();
    }
}
