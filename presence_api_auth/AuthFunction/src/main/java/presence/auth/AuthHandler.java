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
import java.util.stream.Collectors;

/**
 * {@code GET /api/auth}: the signed-in user's roles, as
 * {@code {"email": "...", "roles": [...]}}. The HTTP API's JWT authorizer has
 * already verified the Google ID token, so the claims can be trusted.
 */
public class AuthHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    private final Roles roles;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AuthHandler() {
        this(fromEnvironment());
    }

    AuthHandler(Roles roles) {
        this.roles = roles;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var claims = claims(event);
        var email = claims.get("email");
        var verified = "true".equalsIgnoreCase(claims.getOrDefault("email_verified", ""));
        var granted = roles.of(email, verified);
        var body = "{\"email\":" + (email == null ? "null" : Json.string(email))
                + ",\"roles\":[" + granted.stream().map(Json::string).collect(Collectors.joining(","))
                + "]}";
        return APIGatewayV2HTTPResponse.builder()
                .withStatusCode(200)
                .withHeaders(Map.of("Content-Type", "application/json", "Cache-Control", "no-store"))
                .withBody(body)
                .build();
    }

    private static Map<String, String> claims(APIGatewayV2HTTPEvent event) {
        var context = event == null ? null : event.getRequestContext();
        var authorizer = context == null ? null : context.getAuthorizer();
        var jwt = authorizer == null ? null : authorizer.getJwt();
        var claims = jwt == null ? null : jwt.getClaims();
        return claims == null ? Map.of() : claims;
    }

    private static Roles fromEnvironment() {
        var table = System.getenv("USER_ROLES_TABLE");
        var domain = System.getenv().getOrDefault("PRIVILEGED_DOMAIN", "");
        var domainRoles = Arrays.stream(System.getenv().getOrDefault("DOMAIN_ROLES", "").split(","))
                .map(String::trim)
                .filter(r -> !r.isEmpty())
                .collect(Collectors.toSet());
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
        return new Roles(domain, domainRoles, email -> declaredRoles(dynamo, table, email));
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
