package presence.auth;

import com.fasterxml.jackson.jr.ob.JSON;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;

/**
 * A compact JWS (a JWT) taken apart, unverified: its header, its claims,
 * what was signed and the signature. Verifying is {@link ProviderTokens}'
 * (the providers' ID tokens); signing is {@link SessionTokens}'.
 *
 * @param header       the JOSE header
 * @param claims       the payload's claims
 * @param signingInput {@code <header>.<payload>} as sent, the bytes the signature covers
 * @param signature    the signature's bytes
 */
record Jwt(Map<String, Object> header, Map<String, Object> claims, byte[] signingInput, byte[] signature) {

    /** Longer than any ID token a provider sends; refused before decoding. */
    static final int MAX_LENGTH = 8192;

    /** {@code token} taken apart; IllegalArgumentException unless it's three base64url parts of JSON objects. */
    static Jwt parse(String token) {
        if (token == null || token.length() > MAX_LENGTH) {
            throw new IllegalArgumentException("not a JWT");
        }
        var parts = token.split("\\.", -1);
        if (parts.length != 3 || parts[0].isEmpty() || parts[1].isEmpty() || parts[2].isEmpty()) {
            throw new IllegalArgumentException("not a JWT");
        }
        var decoder = Base64.getUrlDecoder();
        try {
            return new Jwt(object(decoder.decode(parts[0])), object(decoder.decode(parts[1])),
                    (parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII), decoder.decode(parts[2]));
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("not a JWT", e);
        }
    }

    /** A claim or header value as a string (a JSON string or boolean), or null. */
    static String text(Map<String, Object> map, String name) {
        var value = map.get(name);
        return value instanceof String || value instanceof Boolean ? value.toString() : null;
    }

    /** A numeric claim (seconds), or null. */
    static Long seconds(Map<String, Object> map, String name) {
        return map.get(name) instanceof Number n ? n.longValue() : null;
    }

    /** {@code bytes} as unpadded base64url, as JWS parts are. */
    static String base64(byte[] bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    /** A JSON object, as a map; IllegalArgumentException otherwise. */
    static Map<String, Object> object(byte[] json) {
        try {
            var value = JSON.std.anyFrom(new String(json, StandardCharsets.UTF_8));
            if (value instanceof Map<?, ?> map) {
                @SuppressWarnings("unchecked")
                var object = (Map<String, Object>) map;
                return object;
            }
        } catch (IOException | RuntimeException e) {
            throw new IllegalArgumentException("not a JSON object", e);
        }
        throw new IllegalArgumentException("not a JSON object");
    }

    /** {@code value} as JSON. */
    static String json(Object value) {
        try {
            return JSON.std.asString(value);
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
    }
}
