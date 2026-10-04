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

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.BiConsumer;
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
 *       It stays in the table, so the requester's cooldown still holds;</li>
 *   <li>{@code GET /api/auth/vouchers}: every voucher, newest first, as
 *       {@code {"vouchers": [{code, role, expiresAt, maxUses, uses, redeemedBy,
 *       createdBy, createdAt}]}};</li>
 *   <li>{@code POST /api/auth/vouchers}: creates a voucher with a random code
 *       from the form-encoded body {@code role}, {@code expiresAt} (ISO-8601,
 *       in the future, within {@link #MAX_VALIDITY}) and {@code maxUses} (1 to
 *       {@link VoucherHandler#MAX_USES}), and answers it. A {@code presence_admin}
 *       voucher needs a {@code presence_root} caller (403 otherwise);</li>
 *   <li>{@code POST /api/auth/vouchers/delete}: deletes the voucher whose code
 *       is the body.</li>
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

    /** The furthest a voucher may expire. */
    static final Duration MAX_VALIDITY = Duration.ofDays(366);

    private final Roles roles;
    private final Function<String, String> owners;
    private final Backend backend;
    private final VoucherHandler.Store vouchers;
    private final Clock clock;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AdminHandler() {
        this(AuthHandler.fromEnvironment(), AuthHandler.owners(AuthHandler.profilesFromEnvironment()),
                dynamoBackend(System.getenv("MEMBERSHIP_TABLE"), System.getenv("USER_ROLES_TABLE")),
                VoucherHandler.dynamoStore(System.getenv("VOUCHER_TABLE")),
                Clock.systemUTC());
    }

    AdminHandler(Roles roles, Backend backend, VoucherHandler.Store vouchers, Clock clock) {
        this(roles, subject -> null, backend, vouchers, clock);
    }

    /** @param owners for a subject, its profile owner's email ({@link AuthHandler#owners}): a linked subject shares the owner's roles */
    AdminHandler(Roles roles, Function<String, String> owners, Backend backend, VoucherHandler.Store vouchers,
                 Clock clock) {
        this.roles = roles;
        this.owners = owners;
        this.backend = backend;
        this.vouchers = vouchers;
        this.clock = clock;
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
            case "GET /api/auth/vouchers" -> response(200, "{\"vouchers\":["
                    + vouchers.all().stream()
                    .sorted(Comparator.comparing(VoucherHandler.Voucher::createdAt).reversed())
                    .map(VoucherHandler.Voucher::toJson)
                    .collect(Collectors.joining(","))
                    + "]}");
            case "POST /api/auth/vouchers" -> createVoucher(event, claims.get("email"), callerRoles);
            case "POST /api/auth/vouchers/delete" -> {
                var body = MembershipHandler.bodyText(event, 64);
                var code = body == null ? null : VoucherHandler.normalize(body);
                if (code == null) {
                    yield response(400, "{\"error\":\"the body must be a voucher code\"}");
                }
                vouchers.delete(code);
                yield response(200, "{\"code\":" + Json.string(code) + "}");
            }
            default -> response(404, "{\"error\":\"no such route\"}");
        };
    }

    private APIGatewayV2HTTPResponse createVoucher(APIGatewayV2HTTPEvent event, String admin, Set<String> callerRoles) {
        var body = MembershipHandler.bodyText(event, 1000);
        var form = VoucherHandler.form(body == null ? "" : body);
        var role = form.getOrDefault("role", "");
        if (!VoucherHandler.ROLES.contains(role)) {
            return response(400, "{\"error\":\"role must be one of " + String.join(", ", new TreeSet<>(VoucherHandler.ROLES)) + "\"}");
        }
        // Only roots make admins: an admin can't pass the role on.
        if (Roles.ADMIN.equals(role) && !callerRoles.contains(Roles.ROOT)) {
            return response(403, "{\"error\":\"only presence_root creates presence_admin vouchers\"}");
        }
        // Milliseconds, as stored.
        var now = clock.instant().truncatedTo(ChronoUnit.MILLIS);
        Instant expiresAt;
        try {
            expiresAt = Instant.parse(form.getOrDefault("expiresAt", ""));
        } catch (DateTimeParseException e) {
            return response(400, "{\"error\":\"expiresAt must be an ISO-8601 instant\"}");
        }
        if (!expiresAt.isAfter(now) || expiresAt.isAfter(now.plus(MAX_VALIDITY))) {
            return response(400, "{\"error\":\"expiresAt must be in the future, within "
                    + MAX_VALIDITY.toDays() + " days\"}");
        }
        int maxUses;
        try {
            maxUses = Integer.parseInt(form.getOrDefault("maxUses", ""));
        } catch (NumberFormatException e) {
            maxUses = 0;
        }
        if (maxUses < 1 || maxUses > VoucherHandler.MAX_USES) {
            return response(400, "{\"error\":\"maxUses must be 1 to " + VoucherHandler.MAX_USES + "\"}");
        }
        // 60 random bits rarely collide; try again if one does.
        for (var attempt = 0; attempt < 3; attempt++) {
            var voucher = new VoucherHandler.Voucher(VoucherHandler.newCode(), role, expiresAt, maxUses, 0,
                    Set.of(), admin.strip().toLowerCase(Locale.ROOT), now);
            if (vouchers.create(voucher)) {
                return response(201, voucher.toJson());
            }
        }
        return response(500, "{\"error\":\"couldn't pick a free code\"}");
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

            private final BiConsumer<String, Set<String>> grant = dynamoGrant(dynamo, rolesTable);

            @Override
            public void grant(String email, String role) {
                grant.accept(email, Set.of(role));
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

    /** Adds roles to an email's roles in the UserRoles table. */
    static BiConsumer<String, Set<String>> dynamoGrant(String rolesTable) {
        return dynamoGrant(DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build(), rolesTable);
    }

    private static BiConsumer<String, Set<String>> dynamoGrant(DynamoDbClient dynamo, String rolesTable) {
        return (email, roles) -> {
            // Merged and written back as a string set, whatever form (set,
            // list or string) the roles were in.
            var merged = new TreeSet<>(AuthHandler.declaredRoles(dynamo, rolesTable, email));
            merged.addAll(roles);
            dynamo.updateItem(UpdateItemRequest.builder()
                    .tableName(rolesTable)
                    .key(Map.of("email", AttributeValue.fromS(email)))
                    .updateExpression("SET #roles = :roles")
                    .expressionAttributeNames(Map.of("#roles", "roles"))
                    .expressionAttributeValues(Map.of(":roles", AttributeValue.fromSs(List.copyOf(merged))))
                    .build());
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
