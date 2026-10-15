package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.fasterxml.jackson.jr.ob.JSON;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.Supplier;

/** What the recognition handlers share: who may call, and the requests' JSON. */
final class RecognitionApi {

    /** The most crops in one request: each takes DINOv2 about 0.2 s, and a request has 30 s. */
    static final int MAX_CROPS = 8;

    /** A request's most characters: {@link #MAX_CROPS} crops in base64, and change. */
    static final int MAX_BODY = MAX_CROPS * (Embedder.PIXELS * 4 / 3 + 1024);

    static final int MAX_NAME = 100;
    static final int MAX_ID = 64;

    private RecognitionApi() {
    }

    /**
     * The caller's profile, and whether it's premium (cloud recognition is
     * premium only); a free caller's profile isn't looked up for its own
     * sake, so it may be null.
     */
    record Access(String profileId, boolean premium) {
    }

    /**
     * From the environment: the caller's roles from rbacr, with those its
     * existing profile's owner shares (reads only), and only for a premium
     * caller its profile as sign-in gives it (made at its first sign-in,
     * {@code lastSignInAt} written): a free caller is refused before any
     * write.
     */
    static Function<Caller, Access> accessFromEnvironment() {
        return access(Profiles.fromEnvironment(), Roles.fromEnvironment());
    }

    static Function<Caller, Access> access(Profiles profiles, Roles roles) {
        return caller -> {
            if (!roles.of(caller, profiles.existing(caller)).contains(Roles.PREMIUM)) {
                return new Access(null, false);
            }
            var profile = profiles.profile(caller, null);
            return new Access(profile == null ? null : profile.id(),
                    roles.of(caller, profile).contains(Roles.PREMIUM));
        };
    }

    /** The warm-up schedule's {@code rawPath} (template.yaml). */
    static final String WARMUP = "/warmup";

    /**
     * Whether {@code event} is the warm-up schedule's (EventBridge, every 5
     * minutes): no route, which the API always gives, and {@link #WARMUP}.
     * Only EventBridge (or someone with AWS access) can invoke the
     * function so.
     */
    static boolean warmup(APIGatewayV2HTTPEvent event) {
        return event != null && event.getRouteKey() == null && WARMUP.equals(event.getRawPath());
    }

    /**
     * Loads {@code embedder}'s model if this instance hasn't yet, so a
     * person's request finds it ready: a new instance takes over a minute
     * to fetch and load DINOv2, past the API's 30 s
     * (specs/cloud-recognition.md, "Warm-up").
     */
    static APIGatewayV2HTTPResponse warm(Supplier<Embedder> embedder) {
        var started = System.nanoTime();
        embedder.get();
        Timing.log("warm", Timing.since(started), "");
        return Http.response(200, "{\"warm\":true}");
    }

    /** Null if the caller may use cloud recognition; otherwise the answer refusing it. */
    static APIGatewayV2HTTPResponse refusal(Caller caller, Access access) {
        if (!caller.hasSubject() || caller.verifiedEmail() == null) {
            return Http.response(403, "{\"error\":\"a verified email is required\"}");
        }
        if (!access.premium()) {
            return Http.response(403, "{\"error\":\"cloud recognition is premium only\"}");
        }
        if (access.profileId() == null) {
            return Http.response(403, "{\"error\":\"no profile\"}");
        }
        return null;
    }

    /** The body as a JSON object; null if it isn't one (or is too long). */
    static Map<String, Object> body(APIGatewayV2HTTPEvent event) {
        var text = event == null ? null : event.getBody();
        if (text == null || text.length() > MAX_BODY * 2) {
            return null;
        }
        if (event.getIsBase64Encoded()) {
            try {
                text = new String(Base64.getDecoder().decode(text), StandardCharsets.UTF_8);
            } catch (IllegalArgumentException e) {
                return null;
            }
        }
        if (text.length() > MAX_BODY) {
            return null;
        }
        try {
            return JSON.std.mapFrom(text);
        } catch (IOException | RuntimeException e) {
            return null;
        }
    }

    /** {@code map[key]} as a list of objects; null if it isn't one. */
    @SuppressWarnings("unchecked")
    static List<Map<String, Object>> objects(Map<String, Object> map, String key) {
        if (map == null || !(map.get(key) instanceof List<?> list)) {
            return null;
        }
        for (var entry : list) {
            if (!(entry instanceof Map)) {
                return null;
            }
        }
        return (List<Map<String, Object>>) list;
    }

    /** A short string field, or null. */
    static String text(Map<String, Object> map, String key, int max) {
        return map.get(key) instanceof String s && !s.isBlank() && s.length() <= max ? s : null;
    }

    /** A crop's pixels: {@link Embedder#PIXELS} bytes in base64; null otherwise. */
    static byte[] pixels(Map<String, Object> map) {
        if (!(map.get("pixels") instanceof String s)) {
            return null;
        }
        try {
            var bytes = Base64.getDecoder().decode(s);
            return bytes.length == Embedder.PIXELS ? bytes : null;
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    static APIGatewayV2HTTPResponse json(int status, Object value) {
        try {
            return Http.response(status, JSON.std.asString(value));
        } catch (IOException e) {
            throw new IllegalStateException(e);
        }
    }
}
