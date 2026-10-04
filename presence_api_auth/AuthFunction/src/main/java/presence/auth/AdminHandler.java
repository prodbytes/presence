package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeSet;
import java.util.function.Function;
import java.util.stream.Collectors;

import static presence.auth.AuthHandler.response;

/**
 * The Admin screen's API, for users with both {@code presence_user} and
 * {@code presence_admin} (403 otherwise, as the app shows the screen):
 * <ul>
 *   <li>{@code GET /api/auth/membership}: the pending membership requests,
 *       oldest first, as {@code {"requests": [{email, name, message, requestedAt}]}};</li>
 *   <li>{@code POST /api/auth/membership/grant}: gives the email in the
 *       (plain-text) body the {@code presence_user} role and drops its request;</li>
 *   <li>{@code POST /api/auth/membership/dismiss}: hides the email's request.
 *       It stays in the table, so the requester's cooldown still holds.</li>
 * </ul>
 */
public class AdminHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** Where membership requests and granted roles are kept. */
    interface Backend {
        /** The requests that weren't dismissed. */
        List<MembershipHandler.Request> requests();

        /** Adds {@code role} to the email's roles in the UserRoles table. */
        void grant(String email, String role);

        /** Removes the email's request (after a grant). */
        void remove(String email);

        /** Hides the email's request from {@link #requests()}. */
        void dismiss(String email);
    }

    private final Roles roles;
    private final Function<String, String> owners;
    private final Backend backend;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AdminHandler() {
        this(AuthHandler.fromEnvironment(), AuthHandler.ownersFromEnvironment(),
                dynamoBackend(System.getenv("MEMBERSHIP_TABLE"), System.getenv("USER_ROLES_TABLE")));
    }

    AdminHandler(Roles roles, Backend backend) {
        this(roles, sub -> null, backend);
    }

    /** @param owners as in {@link AuthHandler}: an account shares its profile owner's roles */
    AdminHandler(Roles roles, Function<String, String> owners, Backend backend) {
        this.roles = roles;
        this.owners = owners;
        this.backend = backend;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var claims = AuthHandler.claims(event);
        var verified = "true".equalsIgnoreCase(claims.getOrDefault("email_verified", ""));
        var callerRoles = roles.of(claims.get("email"), verified, AuthHandler.ownerOf(owners, claims));
        if (!callerRoles.contains(Roles.USER) || !callerRoles.contains(Roles.ADMIN)) {
            return response(403, "{\"error\":\"administrators only\"}");
        }
        var route = event.getRouteKey() == null ? "" : event.getRouteKey();
        return switch (route) {
            case "GET /api/auth/membership" -> response(200, "{\"requests\":["
                    + backend.requests().stream()
                    .sorted(Comparator.comparing(MembershipHandler.Request::requestedAt))
                    .map(AdminHandler::json)
                    .collect(Collectors.joining(","))
                    + "]}");
            case "POST /api/auth/membership/grant", "POST /api/auth/membership/dismiss" -> {
                var body = MembershipHandler.bodyText(event, 254);
                var email = body == null ? "" : body.toLowerCase(Locale.ROOT);
                if (!validEmail(email)) {
                    yield response(400, "{\"error\":\"the body must be an email\"}");
                }
                if (route.endsWith("/grant")) {
                    backend.grant(email, Roles.USER);
                    backend.remove(email);
                } else {
                    backend.dismiss(email);
                }
                yield response(200, "{\"email\":" + Json.string(email) + "}");
            }
            default -> response(404, "{\"error\":\"no such route\"}");
        };
    }

    /** One address: something@domain, at most 254 characters, no spaces or commas. */
    static boolean validEmail(String email) {
        var at = email.lastIndexOf('@');
        return email.length() <= 254 && at > 0 && at < email.length() - 1
                && email.chars().noneMatch(c -> c <= ' ' || c == ',');
    }

    static String json(MembershipHandler.Request r) {
        return "{\"email\":" + Json.string(r.email())
                + ",\"name\":" + Json.string(r.name())
                + ",\"message\":" + Json.string(r.message())
                + ",\"requestedAt\":" + Json.string(r.requestedAt().toString()) + "}";
    }

    static Backend dynamoBackend(String membershipTable, String rolesTable) {
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
        return new Backend() {
            @Override
            public List<MembershipHandler.Request> requests() {
                var result = new ArrayList<MembershipHandler.Request>();
                // Few requests are ever pending; the paginator reads them all.
                var scan = ScanRequest.builder()
                        .tableName(membershipTable)
                        .filterExpression("attribute_not_exists(dismissed)")
                        .build();
                for (var page : dynamo.scanPaginator(scan)) {
                    for (var item : page.items()) {
                        result.add(new MembershipHandler.Request(
                                text(item, "email"), text(item, "name"), text(item, "message"),
                                instant(item.getOrDefault("requestedAt", AttributeValue.fromN("0")))));
                    }
                }
                return result;
            }

            @Override
            public void grant(String email, String role) {
                // Merged and written back as a string set, whatever form (set,
                // list or string) the roles were in.
                var merged = new TreeSet<>(AuthHandler.declaredRoles(dynamo, rolesTable, email));
                merged.add(role);
                dynamo.updateItem(UpdateItemRequest.builder()
                        .tableName(rolesTable)
                        .key(Map.of("email", AttributeValue.fromS(email)))
                        .updateExpression("SET #roles = :roles")
                        .expressionAttributeNames(Map.of("#roles", "roles"))
                        .expressionAttributeValues(Map.of(":roles", AttributeValue.fromSs(List.copyOf(merged))))
                        .build());
            }

            @Override
            public void remove(String email) {
                dynamo.deleteItem(DeleteItemRequest.builder()
                        .tableName(membershipTable)
                        .key(Map.of("email", AttributeValue.fromS(email)))
                        .build());
            }

            @Override
            public void dismiss(String email) {
                try {
                    dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(membershipTable)
                            .key(Map.of("email", AttributeValue.fromS(email)))
                            .updateExpression("SET dismissed = :yes")
                            // Don't create a row for an email that never asked.
                            .conditionExpression("attribute_exists(email)")
                            .expressionAttributeValues(Map.of(":yes", AttributeValue.fromBool(true)))
                            .build());
                } catch (ConditionalCheckFailedException e) {
                    // Already gone: nothing to dismiss.
                }
            }
        };
    }

    /** Epoch milliseconds (as stored), or the epoch if malformed. */
    private static Instant instant(AttributeValue value) {
        try {
            return Instant.ofEpochMilli(Long.parseLong(value.n()));
        } catch (NumberFormatException | NullPointerException e) {
            return Instant.EPOCH;
        }
    }

    private static String text(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        return value == null || value.s() == null ? "" : value.s();
    }
}
