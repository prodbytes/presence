package presence.auth;

import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.time.Duration;
import java.time.Instant;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.BiConsumer;

/**
 * The UserRoles table, one item per (lowercase) email: its {@code roles}
 * (a string set; a list of strings or one string when written by hand) and
 * the email's recent wrong voucher codes ({@code voucherMisses}, counted
 * since {@code voucherMissesSince}, epoch ms) for
 * {@link VoucherHandler.Lockout}. An item with no {@code roles} declares
 * none.
 */
final class UserRoles {

    /** How many times {@link #grant} retries a concurrent change before it gives up. */
    static final int ATTEMPTS = 5;

    private UserRoles() {
    }

    /** The table's {@code roles} for {@code email}: a string set or a list of strings. */
    static Set<String> declared(DynamoDbClient dynamo, String table, String email) {
        var item = dynamo.getItem(GetItemRequest.builder()
                .tableName(table)
                .key(key(email))
                .build()).item();
        return parse(item == null ? null : item.get("roles"));
    }

    private static Set<String> parse(AttributeValue roles) {
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

    /** Adds roles to an email's roles, as {@link #grant(DynamoDbClient, String, String, Set)}. */
    static BiConsumer<String, Set<String>> grant(DynamoDbClient dynamo, String table) {
        return (email, roles) -> grant(dynamo, table, email, roles);
    }

    /**
     * Adds {@code roles} to the email's, atomically: {@code ADD} to the
     * string set, so concurrent grants never lose each other's roles. Roles
     * written by hand as a list or a string are first rewritten as a set,
     * conditional on them not having changed since read (retried).
     */
    static void grant(DynamoDbClient dynamo, String table, String email, Set<String> roles) {
        var names = Map.of("#roles", "roles");
        var added = AttributeValue.fromSs(List.copyOf(new TreeSet<>(roles)));
        for (var attempt = 0; attempt < ATTEMPTS; attempt++) {
            try {
                dynamo.updateItem(UpdateItemRequest.builder()
                        .tableName(table)
                        .key(key(email))
                        .updateExpression("ADD #roles :roles")
                        .conditionExpression("attribute_not_exists(#roles) OR attribute_type(#roles, :ss)")
                        .expressionAttributeNames(names)
                        .expressionAttributeValues(Map.of(":roles", added, ":ss", AttributeValue.fromS("SS")))
                        .build());
                return;
            } catch (ConditionalCheckFailedException e) {
                // A list or a string: rewritten as a set below.
            }
            var item = dynamo.getItem(GetItemRequest.builder()
                    .tableName(table)
                    .key(key(email))
                    .consistentRead(true)
                    .build()).item();
            var old = item == null ? null : item.get("roles");
            if (old == null || old.hasSs()) {
                // Changed meanwhile into something ADD takes: add again.
                continue;
            }
            var merged = new TreeSet<>(parse(old));
            merged.addAll(roles);
            try {
                dynamo.updateItem(UpdateItemRequest.builder()
                        .tableName(table)
                        .key(key(email))
                        .updateExpression("SET #roles = :roles")
                        .conditionExpression("#roles = :old")
                        .expressionAttributeNames(names)
                        .expressionAttributeValues(Map.of(
                                ":roles", AttributeValue.fromSs(List.copyOf(merged)), ":old", old))
                        .build());
                return;
            } catch (ConditionalCheckFailedException e) {
                // Changed since read: try again.
            }
        }
        throw new IllegalStateException("the roles kept changing during " + ATTEMPTS + " attempts");
    }

    /**
     * {@link VoucherHandler.Lockout} on this table: at most {@code max}
     * wrong codes per email in a {@code window} that starts at its first.
     */
    static VoucherHandler.Lockout lockout(DynamoDbClient dynamo, String table, int max, Duration window) {
        return new VoucherHandler.Lockout() {
            @Override
            public boolean locked(String email, Instant now) {
                var item = dynamo.getItem(GetItemRequest.builder()
                        .tableName(table)
                        .key(key(email))
                        .consistentRead(true)
                        .projectionExpression("voucherMisses, voucherMissesSince")
                        .build()).item();
                if (item == null || item.isEmpty()) {
                    return false;
                }
                return Attrs.number(item.get("voucherMisses")) >= max
                        && Attrs.instant(item.get("voucherMissesSince")).isAfter(now.minus(window));
            }

            @Override
            public void miss(String email, Instant now) {
                var cutoff = Attrs.millis(now.minus(window));
                try {
                    // In the current window: count it.
                    dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(table)
                            .key(key(email))
                            .updateExpression("ADD voucherMisses :one")
                            .conditionExpression("voucherMissesSince > :cutoff")
                            .expressionAttributeValues(Map.of(":one", AttributeValue.fromN("1"), ":cutoff", cutoff))
                            .build());
                    return;
                } catch (ConditionalCheckFailedException e) {
                    // No window, or an old one: start one.
                }
                try {
                    dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(table)
                            .key(key(email))
                            .updateExpression("SET voucherMisses = :one, voucherMissesSince = :now")
                            .conditionExpression("attribute_not_exists(voucherMissesSince)"
                                    + " OR voucherMissesSince <= :cutoff")
                            .expressionAttributeValues(Map.of(":one", AttributeValue.fromN("1"),
                                    ":now", Attrs.millis(now), ":cutoff", cutoff))
                            .build());
                } catch (ConditionalCheckFailedException e) {
                    // A concurrent miss started it: this one goes uncounted.
                }
            }
        };
    }

    private static Map<String, AttributeValue> key(String email) {
        return Map.of("email", AttributeValue.fromS(email));
    }
}
