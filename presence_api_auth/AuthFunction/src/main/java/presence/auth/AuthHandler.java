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
 * {@code GET /api/auth}: the signed-in user's roles, as
 * {@code {"email": "...", "roles": [...]}}. The HTTP API's JWT authorizer has
 * already verified the Google ID token, so the claims can be trusted.
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
    private final Function<String, String> owners;
    private final ExecutionMode mode;
    private final Settings settings;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AuthHandler() {
        this(fromEnvironment(), ownersFromEnvironment(), ExecutionMode.fromEnvironment(), Settings.fromEnvironment());
    }

    AuthHandler(Roles roles) {
        this(roles, ExecutionMode.RBAC);
    }

    AuthHandler(Roles roles, ExecutionMode mode) {
        this(roles, mode, new Settings(mode == ExecutionMode.RBAC, false));
    }

    AuthHandler(Roles roles, ExecutionMode mode, Settings settings) {
        this(roles, sub -> null, mode, settings);
    }

    /**
     * @param owners for a Google account ID, the email of its profile's owner
     *               (whose roles it shares), or null; see {@link Profiles}
     */
    AuthHandler(Roles roles, Function<String, String> owners, ExecutionMode mode, Settings settings) {
        this.roles = roles;
        this.owners = owners;
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
        var granted = roles.of(email, verified, ownerOf(owners, claims));
        var body = "{\"email\":" + (email == null ? "null" : Json.string(email))
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

    /** The signed-in account's profile owner's email, or null (none yet, or no {@code sub}). */
    static String ownerOf(Function<String, String> owners, Map<String, String> claims) {
        var sub = claims.get("sub");
        return sub == null || sub.isBlank() ? null : owners.apply(sub);
    }

    /** Owner emails from the accounts table ({@code ACCOUNTS_TABLE}); none when it isn't set. */
    static Function<String, String> ownersFromEnvironment() {
        var table = System.getenv("ACCOUNTS_TABLE");
        if (table == null || table.isBlank()) {
            return sub -> null;
        }
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
        return sub -> {
            var item = dynamo.getItem(GetItemRequest.builder()
                    .tableName(table)
                    .key(Map.of("sub", AttributeValue.fromS(sub)))
                    .projectionExpression("ownerEmail")
                    .build()).item();
            var owner = item == null ? null : item.get("ownerEmail");
            return owner == null ? null : owner.s();
        };
    }

    static Roles fromEnvironment() {
        var table = System.getenv("USER_ROLES_TABLE");
        var domains = list(System.getenv("ALLOWED_DOMAINS"));
        var domainRoles = list(System.getenv("DOMAIN_ROLES"));
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
        return new Roles(domains, domainRoles, email -> declaredRoles(dynamo, table, email));
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
