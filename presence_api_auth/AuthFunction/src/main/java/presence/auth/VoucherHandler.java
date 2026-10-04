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
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.BiConsumer;
import java.util.stream.Collectors;

import static presence.auth.AuthHandler.response;

/**
 * {@code POST /api/auth/voucher}: a signed-in user redeems a voucher code
 * (the plain-text body). A valid code (it exists, hasn't expired, has uses
 * left, and this email hasn't used it) counts a use and grants its role.
 * Every other code gets the same 404, so an answer tells nothing about
 * which codes exist. Admins create vouchers on the Admin screen (see
 * {@link AdminHandler}).
 */
public class VoucherHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** The roles a voucher may grant; never {@link Roles#ROOT}, which only the allowlist gives. */
    static final Set<String> ROLES = Set.of(Roles.USER, Roles.ADMIN);

    /** The most uses one voucher may have. */
    static final int MAX_USES = 1000;

    /** Codes are three groups of four, from 32 characters without 0/O or 1/I: 60 random bits. */
    static final String ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    private static final SecureRandom RANDOM = new SecureRandom();

    /** A voucher, as stored and listed. */
    record Voucher(String code, String role, Instant expiresAt, int maxUses, int uses,
                   Set<String> redeemedBy, String createdBy, Instant createdAt) {

        String toJson() {
            return "{\"code\":" + Json.string(code)
                    + ",\"role\":" + Json.string(role)
                    + ",\"expiresAt\":" + Json.string(expiresAt.toString())
                    + ",\"maxUses\":" + maxUses
                    + ",\"uses\":" + uses
                    + ",\"redeemedBy\":[" + redeemedBy.stream().sorted().map(Json::string)
                    .collect(Collectors.joining(",")) + "]"
                    + ",\"createdBy\":" + Json.string(createdBy)
                    + ",\"createdAt\":" + Json.string(createdAt.toString()) + "}";
        }
    }

    /** Where vouchers are kept. */
    interface Store {
        /** Saves a new voucher; false if its code is taken. */
        boolean create(Voucher voucher);

        /** Every voucher, used up and expired ones too. */
        List<Voucher> all();

        /** Deletes the voucher, if there is one. */
        void delete(String code);

        /**
         * Counts a use of {@code code} by {@code email}, if it exists, expires
         * after {@code now}, has uses left and {@code email} hasn't used it.
         *
         * @return the voucher's role, or null if it can't be used
         */
        String claim(String code, String email, Instant now);

        /** Undoes {@link #claim} (when the grant failed). */
        void release(String code, String email);
    }

    private final Store store;
    private final BiConsumer<String, Set<String>> grant;
    private final Clock clock;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public VoucherHandler() {
        this(dynamoStore(System.getenv("VOUCHER_TABLE")),
                AdminHandler.dynamoGrant(System.getenv("USER_ROLES_TABLE")),
                Clock.systemUTC());
    }

    /** @param grant adds roles to an email's roles in the UserRoles table */
    VoucherHandler(Store store, BiConsumer<String, Set<String>> grant, Clock clock) {
        this.store = store;
        this.grant = grant;
        this.clock = clock;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var claims = AuthHandler.claims(event);
        var rawEmail = claims.get("email");
        var verified = "true".equalsIgnoreCase(claims.getOrDefault("email_verified", ""));
        if (rawEmail == null || rawEmail.isBlank() || !verified) {
            return response(403, "{\"error\":\"a verified email is required\"}");
        }
        var email = rawEmail.strip().toLowerCase(Locale.ROOT);
        var body = MembershipHandler.bodyText(event, 64);
        if (body == null || body.isEmpty()) {
            return response(400, "{\"error\":\"the body must be a voucher code\"}");
        }
        var code = normalize(body);
        var role = code == null ? null : store.claim(code, email, clock.instant());
        if (role == null) {
            return response(404, "{\"error\":\"the code is invalid, expired or used up\"}");
        }
        var roles = rolesFor(role);
        try {
            grant.accept(email, roles);
        } catch (RuntimeException e) {
            store.release(code, email);
            throw e;
        }
        return response(200, "{\"role\":" + Json.string(role) + ",\"granted\":["
                + roles.stream().map(Json::string).collect(Collectors.joining(",")) + "]}");
    }

    /**
     * What a voucher's role grants: {@code presence_admin} comes with
     * {@code presence_user}, since the Admin screen needs both.
     */
    static Set<String> rolesFor(String role) {
        var roles = new TreeSet<String>();
        roles.add(role);
        if (Roles.ADMIN.equals(role)) {
            roles.add(Roles.USER);
        }
        return roles;
    }

    /** A new random code, {@code XXXX-XXXX-XXXX}. */
    static String newCode() {
        var raw = new StringBuilder(12);
        for (var i = 0; i < 12; i++) {
            raw.append(ALPHABET.charAt(RANDOM.nextInt(ALPHABET.length())));
        }
        return normalize(raw.toString());
    }

    /**
     * A typed code in its stored form, {@code XXXX-XXXX-XXXX}: case, spaces
     * and dashes don't matter. Null if it can't be a code.
     */
    static String normalize(String typed) {
        var raw = typed.toUpperCase(Locale.ROOT).replaceAll("[\\s-]", "");
        if (raw.length() != 12 || raw.chars().anyMatch(c -> ALPHABET.indexOf(c) < 0)) {
            return null;
        }
        return raw.substring(0, 4) + "-" + raw.substring(4, 8) + "-" + raw.substring(8);
    }

    /** An {@code application/x-www-form-urlencoded} body's fields (the last of repeated ones). */
    static Map<String, String> form(String body) {
        var fields = new HashMap<String, String>();
        for (var pair : body.split("&")) {
            if (pair.isEmpty()) {
                continue;
            }
            var eq = pair.indexOf('=');
            try {
                var name = URLDecoder.decode(eq < 0 ? pair : pair.substring(0, eq), StandardCharsets.UTF_8);
                var value = eq < 0 ? "" : URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8);
                fields.put(name, value);
            } catch (IllegalArgumentException e) {
                // A malformed escape: skip the field.
            }
        }
        return fields;
    }

    /**
     * One item per code: {@code {"code", "role", "expiresAt" (epoch ms),
     * "maxUses", "uses", "redeemedBy" (SS), "createdBy", "createdAt" (epoch ms)}}.
     */
    static Store dynamoStore(String table) {
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
        return new Store() {
            @Override
            public boolean create(Voucher voucher) {
                try {
                    dynamo.putItem(PutItemRequest.builder()
                            .tableName(table)
                            .item(Map.of(
                                    "code", AttributeValue.fromS(voucher.code()),
                                    "role", AttributeValue.fromS(voucher.role()),
                                    "expiresAt", millis(voucher.expiresAt()),
                                    "maxUses", AttributeValue.fromN(Integer.toString(voucher.maxUses())),
                                    "uses", AttributeValue.fromN("0"),
                                    "createdBy", AttributeValue.fromS(voucher.createdBy()),
                                    "createdAt", millis(voucher.createdAt())))
                            .conditionExpression("attribute_not_exists(code)")
                            .build());
                    return true;
                } catch (ConditionalCheckFailedException e) {
                    return false;
                }
            }

            @Override
            public List<Voucher> all() {
                var result = new ArrayList<Voucher>();
                for (var page : dynamo.scanPaginator(ScanRequest.builder().tableName(table).build())) {
                    for (var item : page.items()) {
                        var redeemedBy = item.get("redeemedBy");
                        result.add(new Voucher(
                                text(item, "code"), text(item, "role"),
                                instant(item.get("expiresAt")), number(item.get("maxUses")),
                                number(item.get("uses")),
                                redeemedBy == null || !redeemedBy.hasSs() ? Set.of() : Set.copyOf(redeemedBy.ss()),
                                text(item, "createdBy"), instant(item.get("createdAt"))));
                    }
                }
                return result;
            }

            @Override
            public void delete(String code) {
                dynamo.deleteItem(DeleteItemRequest.builder()
                        .tableName(table)
                        .key(Map.of("code", AttributeValue.fromS(code)))
                        .build());
            }

            @Override
            public String claim(String code, String email, Instant now) {
                try {
                    var updated = dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(table)
                            .key(Map.of("code", AttributeValue.fromS(code)))
                            // One conditional write: concurrent redemptions can't overspend it.
                            .updateExpression("SET uses = uses + :one ADD redeemedBy :who")
                            .conditionExpression("attribute_exists(code) AND expiresAt > :now"
                                    + " AND uses < maxUses AND NOT contains(redeemedBy, :email)")
                            .expressionAttributeValues(Map.of(
                                    ":one", AttributeValue.fromN("1"),
                                    ":who", AttributeValue.fromSs(List.of(email)),
                                    ":email", AttributeValue.fromS(email),
                                    ":now", millis(now)))
                            .returnValues(ReturnValue.ALL_NEW)
                            .build());
                    var role = updated.attributes().get("role");
                    return role == null ? null : role.s();
                } catch (ConditionalCheckFailedException e) {
                    return null;
                }
            }

            @Override
            public void release(String code, String email) {
                try {
                    dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(table)
                            .key(Map.of("code", AttributeValue.fromS(code)))
                            .updateExpression("SET uses = uses - :one DELETE redeemedBy :who")
                            .conditionExpression("contains(redeemedBy, :email)")
                            .expressionAttributeValues(Map.of(
                                    ":one", AttributeValue.fromN("1"),
                                    ":who", AttributeValue.fromSs(List.of(email)),
                                    ":email", AttributeValue.fromS(email)))
                            .build());
                } catch (ConditionalCheckFailedException e) {
                    // Deleted meanwhile: nothing to give back.
                }
            }
        };
    }

    private static AttributeValue millis(Instant instant) {
        return AttributeValue.fromN(Long.toString(instant.toEpochMilli()));
    }

    /** Epoch milliseconds (as stored), or the epoch if missing or malformed. */
    private static Instant instant(AttributeValue value) {
        try {
            return Instant.ofEpochMilli(Long.parseLong(value.n()));
        } catch (NumberFormatException | NullPointerException e) {
            return Instant.EPOCH;
        }
    }

    private static int number(AttributeValue value) {
        try {
            return Integer.parseInt(value.n());
        } catch (NumberFormatException | NullPointerException e) {
            return 0;
        }
    }

    private static String text(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        return value == null || value.s() == null ? "" : value.s();
    }
}
