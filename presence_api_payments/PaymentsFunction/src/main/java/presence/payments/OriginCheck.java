package presence.payments;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;

/**
 * Whether a request came through the site's CloudFront distribution: it
 * adds {@link #HEADER} with the stage's secret to every request it sends
 * this API (presence_infra/site.yaml, {@code OriginSecret}), overwriting
 * any a caller sent. Calls straight to the API's own {@code execute-api}
 * host lack it and get 403. With no secret configured ({@code
 * ORIGIN_SECRET} empty: locally, or before the site sends it), every
 * request passes (specs/origin-check.md).
 */
final class OriginCheck {

    /** The header CloudFront adds (header names reach Lambda lowercased). */
    static final String HEADER = "x-presence-origin-verify";

    private static final OriginCheck FROM_ENVIRONMENT = new OriginCheck(System.getenv("ORIGIN_SECRET"));

    private static final APIGatewayV2HTTPResponse RESPONSE =
            Http.response(403, "{\"error\":\"use the site: https://presence.nu01.com\"}");

    private final byte[] secret;

    OriginCheck(String secret) {
        this.secret = secret == null || secret.isBlank() ? null : secret.strip().getBytes(StandardCharsets.UTF_8);
    }

    /** The function's: {@code ORIGIN_SECRET}. */
    static OriginCheck fromEnvironment() {
        return FROM_ENVIRONMENT;
    }

    /** Whether {@code event} may go on: no secret configured, or it carries it. */
    boolean allows(APIGatewayV2HTTPEvent event) {
        if (secret == null) {
            return true;
        }
        var headers = event == null ? null : event.getHeaders();
        if (headers == null) {
            return false;
        }
        for (Map.Entry<String, String> header : headers.entrySet()) {
            if (HEADER.equalsIgnoreCase(header.getKey()) && header.getValue() != null) {
                // In constant time: a wrong guess says nothing of how close it was.
                return MessageDigest.isEqual(secret, header.getValue().getBytes(StandardCharsets.UTF_8));
            }
        }
        return false;
    }

    /** What a request that didn't come through the site gets. */
    static APIGatewayV2HTTPResponse refused() {
        return RESPONSE;
    }
}
