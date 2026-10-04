package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;

import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * {@code GET /api/auth}: the signed-in user's {@link Profiles profile} and
 * roles, as {@code {"email": "...", "profile": "<id>", "roles": [...]}}. The
 * profile is found by the token's subject ({@code iss} and {@code sub}), or
 * created and linked to it at the first sign-in, with the app's own profile
 * ID ({@code ?profile=<id>}) when that's free: the first sign-in claims the
 * profile the app made at its start. The HTTP API's JWT
 * authorizer has already verified the Google ID token, so the claims can be
 * trusted.
 *
 * <p>{@code GET /api/auth/anonymous} (no token, no authorizer): the
 * {@link ExecutionMode}, the anonymous user's roles and which expected
 * {@link Settings} are set, as {@code {"mode": "RBAC", "roles":
 * ["presence_anonymous"], "settings": {"oidc": true, "aws": true}}}. The app
 * asks it before it shows anything.
 */
public class AuthHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    static final String ANONYMOUS_ROUTE = "GET /api/auth/anonymous";

    private final Roles roles;
    private final Profiles profiles;
    private final ExecutionMode mode;
    private final Settings settings;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AuthHandler() {
        this(fromEnvironment(), profilesFromEnvironment(), ExecutionMode.fromEnvironment(),
                Settings.fromEnvironment());
    }

    AuthHandler(Roles roles, Profiles profiles) {
        this(roles, profiles, ExecutionMode.RBAC);
    }

    AuthHandler(Roles roles, Profiles profiles, ExecutionMode mode) {
        this(roles, profiles, mode, new Settings(mode == ExecutionMode.RBAC, false));
    }

    AuthHandler(Roles roles, Profiles profiles, ExecutionMode mode, Settings settings) {
        this.roles = roles;
        this.profiles = profiles;
        this.mode = mode;
        this.settings = settings;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        if (event != null && ANONYMOUS_ROUTE.equals(event.getRouteKey())) {
            return response(200, "{\"mode\":" + Json.string(mode.name()) + ",\"roles\":["
                    + Roles.anonymous(mode).stream().map(Json::string).collect(Collectors.joining(","))
                    + "],\"settings\":" + settings.toJson() + "}");
        }
        var claims = claims(event);
        var email = claims.get("email");
        var verified = "true".equalsIgnoreCase(claims.getOrDefault("email_verified", ""));
        var profile = profiles.profile(claims.get("iss"), claims.get("sub"), email, query(event, "profile"));
        // A linked subject shares its profile owner's roles.
        var granted = roles.of(email, verified, profile == null ? null : profile.ownerEmail());
        var body = "{\"email\":" + (email == null ? "null" : Json.string(email))
                + ",\"profile\":" + (profile == null ? "null" : Json.string(profile.id()))
                + ",\"roles\":[" + granted.stream().map(Json::string).collect(Collectors.joining(","))
                + "]}";
        return response(200, body);
    }

    /** A JSON answer that nothing may cache. */
    static APIGatewayV2HTTPResponse response(int status, String json) {
        return APIGatewayV2HTTPResponse.builder()
                .withStatusCode(status)
                .withHeaders(Map.of("Content-Type", "application/json", "Cache-Control", "no-store"))
                .withBody(json)
                .build();
    }

    static Map<String, String> claims(APIGatewayV2HTTPEvent event) {
        var context = event == null ? null : event.getRequestContext();
        var authorizer = context == null ? null : context.getAuthorizer();
        var jwt = authorizer == null ? null : authorizer.getJwt();
        var claims = jwt == null ? null : jwt.getClaims();
        return claims == null ? Map.of() : claims;
    }

    /** The query parameter {@code name}, or null. */
    static String query(APIGatewayV2HTTPEvent event, String name) {
        var parameters = event == null ? null : event.getQueryStringParameters();
        return parameters == null ? null : parameters.get(name);
    }

    /** The email of the signed-in subject's profile owner, without making a profile; null if none. */
    static String ownerOf(Function<String, String> owners, Map<String, String> claims) {
        var iss = claims.get("iss");
        var sub = claims.get("sub");
        return iss == null || iss.isBlank() || sub == null || sub.isBlank()
                ? null : owners.apply(Profiles.subject(iss, sub));
    }

    /** For a subject, its profile owner's email (see {@link #ownerOf}). */
    static Function<String, String> owners(Profiles profiles) {
        return subject -> {
            var profile = profiles.existing(subject);
            return profile == null ? null : profile.ownerEmail();
        };
    }

    static Roles fromEnvironment() {
        var table = System.getenv("USER_ROLES_TABLE");
        var dynamo = dynamo();
        return new Roles(list(System.getenv("PRESENCE_ROOT_DOMAINS")), list(System.getenv("PRESENCE_ROOT_EMAILS")),
                email -> declaredRoles(dynamo, table, email));
    }

    static Profiles profilesFromEnvironment() {
        return new Profiles(Profiles.dynamoStore(dynamo(),
                System.getenv("PROFILES_TABLE"), System.getenv("PROFILE_SUBJECTS_TABLE")));
    }

    static DynamoDbClient dynamo() {
        return DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
    }

    /** A comma-separated setting's non-blank items. */
    static Set<String> list(String value) {
        return Arrays.stream(value == null ? new String[0] : value.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .collect(Collectors.toSet());
    }

    /** The table's {@code roles} for {@code email}: a string set or a list of strings. */
    static Set<String> declaredRoles(DynamoDbClient dynamo, String table, String email) {
        var item = dynamo.getItem(GetItemRequest.builder()
                .tableName(table)
                .key(Map.of("email", AttributeValue.fromS(email)))
                .build()).item();
        var roles = item == null ? null : item.get("roles");
        var result = new LinkedHashSet<String>();
        if (roles == null) {
            return result;
        }
        if (roles.hasSs()) {
            result.addAll(roles.ss());
        } else if (roles.hasL()) {
            roles.l().stream().map(AttributeValue::s).filter(s -> s != null && !s.isBlank()).forEach(result::add);
        } else if (roles.s() != null && !roles.s().isBlank()) {
            result.add(roles.s());
        }
        return result;
    }
}
