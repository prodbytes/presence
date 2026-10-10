package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.BiConsumer;
import java.util.stream.Collectors;

import static presence.auth.Attrs.instant;
import static presence.auth.Attrs.millis;
import static presence.auth.Attrs.number;
import static presence.auth.Attrs.text;
import static presence.auth.Http.response;

/**
 * {@code POST /api/auth/voucher}: a signed-in user redeems a voucher code
 * (the plain-text body). A valid code (it exists, its validity has started
 * and hasn't ended, it has uses left, and this email hasn't used it) with a
 * full (100%) discount counts a use and grants its role in rbacr ({@link
 * Roles#GRANTED_AS}: {@code free} or {@code admin}). A valid code with
 * a smaller discount gets 402 with its discount, and grants nothing and
 * counts no use: the user would pay the rest, which isn't built yet. So a
 * 402 does tell that a partial-discount code exists and is redeemable now
 * (the price of saying what's left to pay). Every other code (unknown,
 * malformed, not yet or no longer valid, used up, or used by this email)
 * gets the same 404, which tells nothing about which of those it is.
 *
 * <p>Guessing is slowed per email as well as by the route's throttle: after
 * {@link #MAX_MISSES} 404s within {@link #MISS_WINDOW} of the first, the
 * email gets 429 until the window ends ({@link Lockout}, kept in the
 * UserRoles table).
 *
 * <p>Admins create vouchers on the Admin screen (see {@link AdminHandler}),
 * with a random code or (Member vouchers only) one they choose, a start and
 * an end of validity, and a discount (a percentage, 100 by default).
 */
public class VoucherHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** The roles a voucher may grant; never {@link Roles#ROOT}, which only rbacr's root list gives. */
    static final Set<String> ROLES = Set.of(Roles.USER, Roles.ADMIN);

    /** The most uses one voucher may have. */
    static final int MAX_USES = 1000;

    /** Random codes are three groups of four, from 32 characters without 0/O or 1/I: 60 random bits. */
    static final String ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    /**
     * The length of a code as typed to redeem or delete, dashes included:
     * vouchers made before {@link #MIN_CHOSEN} may be this short.
     */
    static final int MIN_CODE = 6;
    static final int MAX_CODE = 40;

    /**
     * The fewest letters and digits (dashes aside) a new chosen code may
     * have. A chosen code is the voucher's only secret, so it must not be
     * short; presence_admin vouchers can't have one at all.
     */
    static final int MIN_CHOSEN = 10;

    /** How many wrong codes an email may try within {@link #MISS_WINDOW} of its first. */
    static final int MAX_MISSES = 10;
    static final Duration MISS_WINDOW = Duration.ofHours(1);

    /** A voucher's discount, in percent, when none is given. */
    static final int FULL_DISCOUNT = 100;

    private static final SecureRandom RANDOM = new SecureRandom();

    /** A voucher, as stored and listed. */
    record Voucher(String code, String role, Instant startsAt, Instant expiresAt, int maxUses, int uses,
                   Set<String> redeemedBy, String createdBy, Instant createdAt, int discount) {

        String toJson() {
            return toJson(true);
        }

        /**
         * As listed; without {@code reveal}, the code is null and
         * {@code "hidden": true} (presence_admin vouchers, for non-roots).
         */
        String toJson(boolean reveal) {
            return "{\"code\":" + (reveal ? Json.string(code) : "null")
                    + (reveal ? "" : ",\"hidden\":true")
                    + ",\"role\":" + Json.string(role)
                    + ",\"startsAt\":" + Json.string(startsAt.toString())
                    + ",\"expiresAt\":" + Json.string(expiresAt.toString())
                    + ",\"maxUses\":" + maxUses
                    + ",\"uses\":" + uses
                    + ",\"redeemedBy\":[" + redeemedBy.stream().sorted().map(Json::string)
                    .collect(Collectors.joining(",")) + "]"
                    + ",\"createdBy\":" + Json.string(createdBy)
                    + ",\"createdAt\":" + Json.string(createdAt.toString())
                    + ",\"discount\":" + discount + "}";
        }

        /** Whether {@code email} may redeem it at {@code now}, payment aside. */
        boolean redeemableBy(String email, Instant now) {
            return !startsAt.isAfter(now) && expiresAt.isAfter(now) && uses < maxUses && !redeemedBy.contains(email);
        }
    }

    /** Where vouchers are kept. */
    interface Store {
        /** Saves a new voucher; false if its code is taken. */
        boolean create(Voucher voucher);

        /** Every voucher, used up and expired ones too. */
        List<Voucher> all();

        /**
         * Deletes the voucher, if there is one; a presence_admin one only
         * with {@code admins}.
         *
         * @return false if it's a presence_admin voucher and {@code admins} is false (nothing deleted)
         */
        boolean delete(String code, boolean admins);

        /** The voucher, or null if there's none. */
        Voucher find(String code);

        /**
         * Counts a use of {@code code} by {@code email}, if it exists, starts
         * by and expires after {@code now}, has uses left, {@code email} hasn't used it, and
         * its discount is full (nothing left to pay).
         *
         * @return the voucher, as claimed, or null if it can't be used
         */
        Voucher claim(String code, String email, Instant now);

        /** Undoes {@link #claim} (when the grant failed). */
        void release(String code, String email);
    }

    /** Each email's recent wrong codes. */
    interface Lockout {
        /** Whether {@code email} had {@link #MAX_MISSES} wrong codes in the window still open at {@code now}. */
        boolean locked(String email, Instant now);

        /** Counts a wrong code by {@code email}. */
        void miss(String email, Instant now);
    }

    private final Store store;
    private final BiConsumer<String, String> grant;
    private final Lockout lockout;
    private final Clock clock;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public VoucherHandler() {
        this(dynamoStore(System.getenv("VOUCHER_TABLE")),
                (email, role) -> Rbacr.fromEnvironment().grant(email, Roles.GRANTED_AS.get(role)),
                UserRoles.lockout(Aws.dynamo(), System.getenv("USER_ROLES_TABLE"), MAX_MISSES, MISS_WINDOW),
                Clock.systemUTC());
    }

    /**
     * @param grant   grants an email a voucher's role (one of {@link #ROLES}) in rbacr
     * @param lockout each email's wrong codes
     */
    VoucherHandler(Store store, BiConsumer<String, String> grant, Lockout lockout, Clock clock) {
        this.store = store;
        this.grant = grant;
        this.lockout = lockout;
        this.clock = clock;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var email = Caller.from(event).verifiedEmail();
        if (email == null) {
            return response(403, "{\"error\":\"a verified email is required\"}");
        }
        var body = Http.bodyText(event, 64);
        if (body == null || body.isEmpty()) {
            return response(400, "{\"error\":\"the body must be a voucher code\"}");
        }
        try {
            return redeem(email, normalize(body));
        } catch (RuntimeException e) {
            return Aws.failed("voucher", Http.route(event), e, context);
        }
    }

    private APIGatewayV2HTTPResponse redeem(String email, String code) {
        var now = clock.instant();
        if (lockout.locked(email, now)) {
            return response(429, "{\"error\":\"too many wrong codes; try again later\"}");
        }
        var voucher = code == null ? null : store.claim(code, email, now);
        if (voucher == null) {
            var partial = code == null ? null : store.find(code);
            if (partial != null && partial.discount() < FULL_DISCOUNT && partial.redeemableBy(email, now)) {
                // Paying the rest isn't built yet: nothing is granted or counted.
                return response(402, "{\"error\":\"the rest must be paid\",\"discount\":"
                        + partial.discount() + "}");
            }
            lockout.miss(email, now);
            return response(404, "{\"error\":\"the code is invalid, expired or used up\"}");
        }
        var role = voucher.role();
        var roles = rolesFor(role);
        try {
            grant.accept(email, role);
        } catch (RuntimeException e) {
            store.release(code, email);
            throw e;
        }
        return response(200, "{\"role\":" + Json.string(role) + ",\"granted\":["
                + roles.stream().map(Json::string).collect(Collectors.joining(","))
                + "],\"discount\":" + voucher.discount() + "}");
    }

    /**
     * The app's roles a voucher's role gives ({@link Roles#FROM} of its
     * rbacr role): {@code presence_admin} comes with {@code presence_user}
     * and {@code presence_premium}.
     */
    static Set<String> rolesFor(String role) {
        var granted = Roles.GRANTED_AS.get(role);
        var roles = new TreeSet<String>();
        Roles.FROM.forEach((given, from) -> {
            if (from.contains(granted)) {
                roles.add(given);
            }
        });
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
     * A typed code in its stored form: upper case, its words (letters and
     * digits) joined by single dashes, {@code AUTUMN-OTTER-4821}. Case and
     * the separators (spaces, dashes, underscores) don't matter. Twelve
     * characters of {@link #ALPHABET}, typed whole or as three fours, take
     * the random codes' form, {@code XXXX-XXXX-XXXX}. Null if it can't be a
     * code: other characters, or not {@link #MIN_CODE} to {@link #MAX_CODE}
     * long.
     */
    static String normalize(String typed) {
        var words = Arrays.stream(typed.toUpperCase(Locale.ROOT).split("[\\s_-]+"))
                .filter(w -> !w.isEmpty())
                .toList();
        var raw = String.join("", words);
        var lengths = words.stream().map(String::length).toList();
        if (raw.length() == 12 && raw.chars().allMatch(c -> ALPHABET.indexOf(c) >= 0)
                && (lengths.equals(List.of(12)) || lengths.equals(List.of(4, 4, 4)))) {
            return raw.substring(0, 4) + "-" + raw.substring(4, 8) + "-" + raw.substring(8);
        }
        var code = String.join("-", words);
        if (code.length() < MIN_CODE || code.length() > MAX_CODE || !code.matches("[A-Z0-9-]+")) {
            return null;
        }
        return code;
    }

    /**
     * A code an admin chose for a new voucher, {@link #normalize normalized};
     * null unless it has at least {@link #MIN_CHOSEN} letters and digits.
     */
    static String chosen(String typed) {
        var code = normalize(typed);
        return code == null || code.replace("-", "").length() < MIN_CHOSEN ? null : code;
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
     * One item per code: {@code {"code", "role", "startsAt" and "expiresAt" (epoch ms),
     * "maxUses", "uses", "redeemedBy" (SS), "createdBy", "createdAt" (epoch ms),
     * "discount" (percent; 100 if missing)}}. Vouchers from before start
     * dates have no {@code startsAt}: they're valid from their creation.
     */
    static Store dynamoStore(String table) {
        var dynamo = Aws.dynamo();
        return new Store() {
            @Override
            public boolean create(Voucher voucher) {
                try {
                    dynamo.putItem(PutItemRequest.builder()
                            .tableName(table)
                            .item(Map.of(
                                    "code", AttributeValue.fromS(voucher.code()),
                                    "role", AttributeValue.fromS(voucher.role()),
                                    "startsAt", millis(voucher.startsAt()),
                                    "expiresAt", millis(voucher.expiresAt()),
                                    "maxUses", AttributeValue.fromN(Integer.toString(voucher.maxUses())),
                                    "uses", AttributeValue.fromN("0"),
                                    "createdBy", AttributeValue.fromS(voucher.createdBy()),
                                    "createdAt", millis(voucher.createdAt()),
                                    "discount", AttributeValue.fromN(Integer.toString(voucher.discount()))))
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
                        result.add(voucher(item));
                    }
                }
                return result;
            }

            @Override
            public Voucher find(String code) {
                var item = dynamo.getItem(GetItemRequest.builder()
                        .tableName(table)
                        .key(Map.of("code", AttributeValue.fromS(code)))
                        .consistentRead(true)
                        .build()).item();
                return item == null || item.isEmpty() ? null : voucher(item);
            }

            @Override
            public boolean delete(String code, boolean admins) {
                var delete = DeleteItemRequest.builder()
                        .tableName(table)
                        .key(Map.of("code", AttributeValue.fromS(code)));
                if (!admins) {
                    // Checked in the same write: the role can't change in between.
                    delete.conditionExpression("attribute_not_exists(code) OR #role <> :admin")
                            .expressionAttributeNames(Map.of("#role", "role"))
                            .expressionAttributeValues(Map.of(":admin", AttributeValue.fromS(Roles.ADMIN)));
                }
                try {
                    dynamo.deleteItem(delete.build());
                    return true;
                } catch (ConditionalCheckFailedException e) {
                    return false;
                }
            }

            @Override
            public Voucher claim(String code, String email, Instant now) {
                try {
                    var updated = dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(table)
                            .key(Map.of("code", AttributeValue.fromS(code)))
                            // One conditional write: concurrent redemptions can't overspend it.
                            .updateExpression("SET uses = uses + :one ADD redeemedBy :who")
                            // Vouchers from before discounts have none: they're full.
                            // Vouchers from before start dates have none: they started when made.
                            .conditionExpression("attribute_exists(code)"
                                    + " AND (attribute_not_exists(startsAt) OR startsAt <= :now)"
                                    + " AND expiresAt > :now"
                                    + " AND uses < maxUses AND NOT contains(redeemedBy, :email)"
                                    + " AND (attribute_not_exists(discount) OR discount >= :full)")
                            .expressionAttributeValues(Map.of(
                                    ":one", AttributeValue.fromN("1"),
                                    ":full", AttributeValue.fromN(Integer.toString(FULL_DISCOUNT)),
                                    ":who", AttributeValue.fromSs(List.of(email)),
                                    ":email", AttributeValue.fromS(email),
                                    ":now", millis(now)))
                            .returnValues(ReturnValue.ALL_NEW)
                            .build());
                    return voucher(updated.attributes());
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

    private static Voucher voucher(Map<String, AttributeValue> item) {
        var redeemedBy = item.get("redeemedBy");
        var discount = item.get("discount");
        var createdAt = instant(item.get("createdAt"));
        var startsAt = item.get("startsAt");
        return new Voucher(
                text(item, "code"), text(item, "role"),
                // Vouchers from before start dates were valid from their creation.
                startsAt == null ? createdAt : instant(startsAt),
                instant(item.get("expiresAt")), number(item.get("maxUses")),
                number(item.get("uses")),
                redeemedBy == null || !redeemedBy.hasSs() ? Set.of() : Set.copyOf(redeemedBy.ss()),
                text(item, "createdBy"), createdAt,
                // Vouchers from before discounts were full ones.
                discount == null ? FULL_DISCOUNT : number(discount));
    }
}
