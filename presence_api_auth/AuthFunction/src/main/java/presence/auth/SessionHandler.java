package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.services.kms.KmsClient;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.util.LinkedHashMap;
import java.util.Map;

import static presence.auth.Http.response;

/**
 * Presence sessions ({@code SessionFunction}; public routes, no
 * authorizer: each request carries its own proof):
 * <ul>
 *   <li>{@code POST /api/auth/session} {@code {"provider": "google" |
 *       "apple", "idToken", "nonce"?, "authorizationCode"?, "name"?,
 *       "refresh"?}}: verifies the provider's ID token ({@link
 *       ProviderTokens}) and answers a Presence session, {@code {"token",
 *       "expiresAt" (epoch s), "refreshToken"}} (no refresh token with
 *       {@code "refresh": false}, the streamer's way). Apple's name, which
 *       Apple gives the app only at the first sign-in, is kept ({@link
 *       Identities}) and goes in every later token; with an authorization
 *       code and Apple's key, Apple's refresh token is kept for account
 *       deletion ({@link AppleAccounts}). 401 for a token that isn't
 *       good, 403 without a verified email, 503 for a provider without
 *       clients;</li>
 *   <li>{@code POST /api/auth/session/refresh} {@code {"refreshToken"}}: a
 *       new token and refresh token ({@link Sessions}: rotated, reuse
 *       revokes the session), or 401;</li>
 *   <li>{@code POST /api/auth/session/revoke} {@code {"refreshToken"}}: 204,
 *       whatever the token (sign-out);</li>
 *   <li>{@code GET /api/auth/.well-known/openid-configuration} and {@code
 *       /jwks.json}: the issuer and its public key, which API Gateway's JWT
 *       authorizers (this API's and the payments API's) and rbacr fetch to
 *       verify session tokens.</li>
 * </ul>
 * No token (the provider's, a session's or a refresh token) is ever logged.
 */
public class SessionHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    static final String EXCHANGE = "POST /api/auth/session";
    static final String REFRESH = "POST /api/auth/session/refresh";
    static final String REVOKE = "POST /api/auth/session/revoke";
    static final String DISCOVERY = "GET /api/auth/.well-known/openid-configuration";
    static final String JWKS = "GET /api/auth/.well-known/jwks.json";

    /** More than any request here needs (an ID token is a few KB). */
    static final int MAX_BODY = 16 * 1024;

    /** The longest name kept from Apple's sign-in. */
    static final int MAX_NAME = 100;

    private final ProviderTokens providers;
    private final SessionTokens tokens;
    private final Sessions sessions;
    private final Identities identities;
    private final AppleAccounts apple;
    private final Clock clock;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public SessionHandler() {
        this(Environment.INSTANCE);
    }

    private SessionHandler(Environment environment) {
        this(environment.providers, environment.tokens, environment.sessions, environment.store,
                environment.apple, Clock.systemUTC());
    }

    SessionHandler(ProviderTokens providers, SessionTokens tokens, Sessions sessions, Identities identities,
                   AppleAccounts apple, Clock clock) {
        this.providers = providers;
        this.tokens = tokens;
        this.sessions = sessions;
        this.identities = identities;
        this.apple = apple;
        this.clock = clock;
    }

    /** The function instance's clients, made once (Lambda's init phase). */
    private static final class Environment {
        static final Environment INSTANCE = new Environment();

        final ProviderTokens providers = ProviderTokens.fromEnvironment();
        final DynamoSessions store = DynamoSessions.fromEnvironment();
        final Sessions sessions = new Sessions(store, new SecureRandom(), Clock.systemUTC());
        final SessionTokens tokens = new SessionTokens(
                new SessionSigner.Kms(KmsClient.builder().httpClient(Aws.http()).build(),
                        System.getenv("SIGNING_KEY_ARN")),
                System.getenv("SESSION_ISSUER"), Clock.systemUTC());
        final AppleAccounts apple = AppleAccounts.fromEnvironment(store);
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        // Only through the site (CloudFront), never the API's own host: the
        // issuer URL is the site's, so the authorizers' fetches come that way.
        if (!OriginCheck.fromEnvironment().allows(event)) {
            return OriginCheck.refused();
        }
        var route = Http.route(event);
        try {
            return switch (route) {
                case DISCOVERY -> published(tokens.discovery());
                case JWKS -> published(tokens.jwks());
                case EXCHANGE, REFRESH, REVOKE -> {
                    var body = body(event);
                    if (body == null) {
                        yield response(400, "{\"error\":\"the body must be a JSON object\"}");
                    }
                    yield switch (route) {
                        case EXCHANGE -> exchange(body);
                        case REFRESH -> refresh(body);
                        default -> revoke(body);
                    };
                }
                default -> response(404, "{\"error\":\"no such route\"}");
            };
        } catch (RuntimeException e) {
            return Aws.failed("session", route, e, context);
        }
    }

    private APIGatewayV2HTTPResponse exchange(Map<String, Object> body) {
        var provider = string(body, "provider", 16);
        var idToken = string(body, "idToken", Jwt.MAX_LENGTH);
        if (provider == null || idToken == null || !(provider.equals("google") || provider.equals("apple"))) {
            return response(400, "{\"error\":\"provider (google or apple) and idToken are required\"}");
        }
        if (!providers.configured(provider)) {
            return response(503, "{\"error\":" + Json.string(provider + " sign-in isn't set up") + "}");
        }
        ProviderTokens.Identity identity;
        try {
            identity = providers.verify(provider, idToken, string(body, "nonce", 512));
        } catch (ProviderTokens.UnverifiedEmail e) {
            return response(403, "{\"error\":\"a verified email is required\"}");
        } catch (ProviderTokens.Refused e) {
            System.err.println("presence: a " + provider + " ID token was refused: " + e.getMessage());
            return response(401, "{\"error\":\"the sign-in token was refused\"}");
        }
        var subject = identity.subject();
        var name = identity.name();
        if (ProviderTokens.APPLE.equals(identity.idp())) {
            // Apple tells the app the name only at the first sign-in: kept, so
            // every later session (and other devices) still has it.
            var given = name(body.get("name"));
            if (given != null) {
                identities.saveName(subject, given, clock.instant());
                name = given;
            } else {
                name = identities.get(subject).map(Identities.Identity::name).orElse(null);
            }
            var code = string(body, "authorizationCode", 2048);
            if (code != null && apple.configured()) {
                apple.keep(subject, identity.audience(), code);
            }
        }
        var who = new Sessions.Who(identity.idp(), identity.sub(), identity.email(), name, identity.picture(),
                identity.hd());
        var refresh = !Boolean.FALSE.equals(body.get("refresh"));
        return issued(who, refresh ? sessions.start(who) : null);
    }

    private APIGatewayV2HTTPResponse refresh(Map<String, Object> body) {
        var issued = sessions.refresh(string(body, "refreshToken", 128));
        if (issued.isEmpty()) {
            return response(401, "{\"error\":\"the session ended; sign in again\"}");
        }
        return issued(issued.get().who(), issued.get().refreshToken());
    }

    private APIGatewayV2HTTPResponse revoke(Map<String, Object> body) {
        sessions.revoke(string(body, "refreshToken", 128));
        return APIGatewayV2HTTPResponse.builder().withStatusCode(204)
                .withHeaders(Map.of("Cache-Control", "no-store")).build();
    }

    private APIGatewayV2HTTPResponse issued(Sessions.Who who, String refreshToken) {
        var minted = tokens.mint(who);
        var answer = new LinkedHashMap<String, Object>();
        answer.put("token", minted.token());
        answer.put("expiresAt", minted.expiresAt().getEpochSecond());
        if (refreshToken != null) {
            answer.put("refreshToken", refreshToken);
        }
        return response(200, Jwt.json(answer));
    }

    /** Public documents: cacheable for an hour. */
    private static APIGatewayV2HTTPResponse published(String json) {
        return APIGatewayV2HTTPResponse.builder()
                .withStatusCode(200)
                .withHeaders(Map.of("Content-Type", "application/json", "Cache-Control", "public, max-age=3600"))
                .withBody(json)
                .build();
    }

    /** The body as a JSON object, or null. */
    private static Map<String, Object> body(APIGatewayV2HTTPEvent event) {
        var text = Http.bodyText(event, MAX_BODY);
        if (text == null || text.isEmpty()) {
            return null;
        }
        try {
            return Jwt.object(text.getBytes(StandardCharsets.UTF_8));
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    /** A string field no longer than {@code max}, trimmed; null if missing, blank, too long or not a string. */
    private static String string(Map<String, Object> body, String name, int max) {
        if (!(body.get(name) instanceof String value)) {
            return null;
        }
        value = value.strip();
        return value.isEmpty() || value.length() > max ? null : value;
    }

    /** A name as given: control characters dropped, spaces collapsed, at most {@link #MAX_NAME}; or null. */
    static String name(Object value) {
        if (!(value instanceof String text)) {
            return null;
        }
        var cleaned = text.codePoints()
                .filter(c -> !Character.isISOControl(c) && Character.getType(c) != Character.FORMAT)
                .collect(StringBuilder::new, StringBuilder::appendCodePoint, StringBuilder::append)
                .toString().replaceAll("\\s+", " ").strip();
        if (cleaned.isEmpty()) {
            return null;
        }
        return cleaned.codePointCount(0, cleaned.length()) > MAX_NAME
                ? cleaned.substring(0, cleaned.offsetByCodePoints(0, MAX_NAME)).strip()
                : cleaned;
    }
}
