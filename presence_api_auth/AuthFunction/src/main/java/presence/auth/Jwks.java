package presence.auth;

import java.math.BigInteger;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.RSAPublicKeySpec;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * A provider's signing keys (its JWKS: Google's or Apple's), by {@code
 * kid}, fetched when first needed and kept for the answer's {@code
 * Cache-Control: max-age} (at most a day, an hour without one). A {@code
 * kid} it doesn't know fetches them again, at most once a minute, so a
 * flood of forged {@code kid}s can't make it hammer the provider. Only RSA
 * keys for signing are kept.
 */
final class Jwks {

    /** How long keys are kept without a {@code max-age}, and at most. */
    static final Duration DEFAULT_FOR = Duration.ofHours(1);
    static final Duration AT_MOST = Duration.ofDays(1);

    /** The least time between two fetches. */
    static final Duration REFETCH_AFTER = Duration.ofMinutes(1);

    static final Duration TIMEOUT = Duration.ofSeconds(3);

    private static final Pattern MAX_AGE = Pattern.compile("max-age=(\\d+)");

    /** What a GET answered: status, {@code Cache-Control} (or null) and body. */
    record Reply(int status, String cacheControl, String body) {
    }

    /** GETs a URL. */
    @FunctionalInterface
    interface Transport {
        Reply get(URI uri) throws Exception;
    }

    private final URI uri;
    private final Transport transport;
    private final Clock clock;
    private Map<String, RSAPublicKey> keys = Map.of();
    private Instant fresh = Instant.EPOCH;
    private Instant fetched = Instant.EPOCH;

    Jwks(URI uri, Transport transport, Clock clock) {
        this.uri = uri;
        this.transport = transport;
        this.clock = clock;
    }

    /** The JDK's HTTP client, within {@link #TIMEOUT}. */
    static Transport http() {
        var client = HttpClient.newBuilder().connectTimeout(TIMEOUT).build();
        return uri -> {
            var response = client.send(HttpRequest.newBuilder(uri).timeout(TIMEOUT).GET().build(),
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            return new Reply(response.statusCode(),
                    response.headers().firstValue("cache-control").orElse(null), response.body());
        };
    }

    /** The key {@code kid}, fetching the keys when they're stale or don't have it (at most once a minute). */
    synchronized Optional<RSAPublicKey> key(String kid) {
        var now = clock.instant();
        var key = now.isBefore(fresh) ? keys.get(kid) : null;
        if (key == null && !now.isBefore(fetched.plus(REFETCH_AFTER))) {
            fetched = now;
            try {
                fetch(now);
            } catch (Exception e) {
                // Kept: the old keys may still do until the next try.
                System.err.println("presence: could not fetch the keys at " + uri + ": " + e);
            }
            key = keys.get(kid);
        } else if (key == null) {
            // Stale but nothing newer yet: the keys we have.
            key = keys.get(kid);
        }
        return Optional.ofNullable(key);
    }

    private void fetch(Instant now) throws Exception {
        var reply = transport.get(uri);
        if (reply.status() != 200) {
            throw new IllegalStateException("HTTP " + reply.status());
        }
        var parsed = parse(reply.body());
        if (parsed.isEmpty()) {
            throw new IllegalStateException("no RSA signing keys");
        }
        keys = parsed;
        fresh = now.plus(cacheFor(reply.cacheControl()));
    }

    /** How long an answer with this {@code Cache-Control} is kept. */
    static Duration cacheFor(String cacheControl) {
        if (cacheControl != null) {
            var m = MAX_AGE.matcher(cacheControl);
            if (m.find()) {
                try {
                    var age = Duration.ofSeconds(Long.parseLong(m.group(1)));
                    return age.compareTo(AT_MOST) > 0 ? AT_MOST : age;
                } catch (NumberFormatException e) {
                    return DEFAULT_FOR;
                }
            }
        }
        return DEFAULT_FOR;
    }

    /** The RSA signing keys of a JWKS document, by {@code kid}. */
    static Map<String, RSAPublicKey> parse(String json) {
        var document = Jwt.object(json.getBytes(StandardCharsets.UTF_8));
        var keys = new HashMap<String, RSAPublicKey>();
        if (!(document.get("keys") instanceof List<?> list)) {
            return keys;
        }
        for (var entry : list) {
            if (!(entry instanceof Map<?, ?> raw)) {
                continue;
            }
            @SuppressWarnings("unchecked")
            var jwk = (Map<String, Object>) raw;
            var kid = Jwt.text(jwk, "kid");
            var use = Jwt.text(jwk, "use");
            if (kid == null || !"RSA".equals(Jwt.text(jwk, "kty")) || use != null && !"sig".equals(use)) {
                continue;
            }
            try {
                keys.put(kid, rsa(Jwt.text(jwk, "n"), Jwt.text(jwk, "e")));
            } catch (GeneralSecurityException | IllegalArgumentException | NullPointerException e) {
                // A malformed key is skipped; the others still verify.
            }
        }
        return keys;
    }

    /** The RSA public key with modulus {@code n} and exponent {@code e} (base64url). */
    static RSAPublicKey rsa(String n, String e) throws GeneralSecurityException {
        var decoder = Base64.getUrlDecoder();
        return (RSAPublicKey) KeyFactory.getInstance("RSA").generatePublic(
                new RSAPublicKeySpec(new BigInteger(1, decoder.decode(n)), new BigInteger(1, decoder.decode(e))));
    }
}
