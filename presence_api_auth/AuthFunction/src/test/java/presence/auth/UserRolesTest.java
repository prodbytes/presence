package presence.auth;

import org.junit.jupiter.api.Test;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemResponse;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemResponse;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class UserRolesTest {

    /**
     * The UserRoles table, evaluating just the update and condition
     * expressions {@link UserRoles} sends, as DynamoDB would.
     */
    private static final class Table implements DynamoDbClient {
        final Map<String, Map<String, AttributeValue>> items = new HashMap<>();
        final List<String> updates = new ArrayList<>();
        /** Runs before a conditional SET of roles is checked: another writer's change. */
        Runnable beforeSet = () -> { };

        @Override
        public GetItemResponse getItem(GetItemRequest request) {
            var item = items.get(request.key().get("email").s());
            return GetItemResponse.builder().item(item == null ? null : Map.copyOf(item)).build();
        }

        @Override
        public UpdateItemResponse updateItem(UpdateItemRequest request) {
            var email = request.key().get("email").s();
            var item = items.computeIfAbsent(email, e -> new HashMap<>(Map.of("email", AttributeValue.fromS(e))));
            var values = request.expressionAttributeValues();
            var roles = item.get("roles");
            updates.add(request.updateExpression());
            switch (request.updateExpression()) {
                case "ADD #roles :roles" -> {
                    if (roles != null && !roles.hasSs()) {
                        throw ConditionalCheckFailedException.builder().build();
                    }
                    var merged = new TreeSet<>(roles == null ? List.of() : roles.ss());
                    merged.addAll(values.get(":roles").ss());
                    item.put("roles", AttributeValue.fromSs(List.copyOf(merged)));
                }
                case "SET #roles = :roles" -> {
                    var change = beforeSet;
                    beforeSet = () -> { };
                    change.run();
                    if (!values.get(":old").equals(item.get("roles"))) {
                        throw ConditionalCheckFailedException.builder().build();
                    }
                    item.put("roles", values.get(":roles"));
                }
                case "ADD voucherMisses :one" -> {
                    var since = item.get("voucherMissesSince");
                    if (since == null || Long.parseLong(since.n()) <= Long.parseLong(values.get(":cutoff").n())) {
                        throw ConditionalCheckFailedException.builder().build();
                    }
                    item.put("voucherMisses", AttributeValue.fromN(
                            Integer.toString(Attrs.number(item.get("voucherMisses")) + 1)));
                }
                case "SET voucherMisses = :one, voucherMissesSince = :now" -> {
                    var since = item.get("voucherMissesSince");
                    if (since != null && Long.parseLong(since.n()) > Long.parseLong(values.get(":cutoff").n())) {
                        throw ConditionalCheckFailedException.builder().build();
                    }
                    item.put("voucherMisses", values.get(":one"));
                    item.put("voucherMissesSince", values.get(":now"));
                }
                default -> throw new AssertionError(request.updateExpression());
            }
            return UpdateItemResponse.builder().build();
        }

        @Override
        public String serviceName() {
            return "dynamodb";
        }

        @Override
        public void close() {
        }
    }

    private final Table table = new Table();

    @Test
    void grantsAddToTheSetInOneWrite() {
        UserRoles.grant(table, "roles", "ana@example.com", Set.of(Roles.USER));
        UserRoles.grant(table, "roles", "ana@example.com", Set.of(Roles.ADMIN, Roles.USER));
        assertEquals(Set.of(Roles.ADMIN, Roles.USER), UserRoles.declared(table, "roles", "ana@example.com"));
        // Never read-modify-write: concurrent grants can't lose each other's roles.
        assertEquals(List.of("ADD #roles :roles", "ADD #roles :roles"), table.updates);
    }

    @Test
    void rolesWrittenByHandAsAListBecomeASet() {
        table.items.put("bob@example.com", new HashMap<>(Map.of("email", AttributeValue.fromS("bob@example.com"),
                "roles", AttributeValue.fromL(List.of(AttributeValue.fromS("viewer"))))));
        UserRoles.grant(table, "roles", "bob@example.com", Set.of(Roles.USER));
        assertTrue(table.items.get("bob@example.com").get("roles").hasSs());
        assertEquals(Set.of("viewer", Roles.USER), UserRoles.declared(table, "roles", "bob@example.com"));
    }

    @Test
    void aConcurrentChangeToAListIsRetriedNotLost() {
        table.items.put("bob@example.com", new HashMap<>(Map.of("email", AttributeValue.fromS("bob@example.com"),
                "roles", AttributeValue.fromS("viewer"))));
        // Someone else edits the roles between the read and the write.
        table.beforeSet = () -> table.items.get("bob@example.com").put("roles", AttributeValue.fromS("editor"));
        UserRoles.grant(table, "roles", "bob@example.com", Set.of(Roles.USER));
        assertEquals(Set.of("editor", Roles.USER), UserRoles.declared(table, "roles", "bob@example.com"));
    }

    @Test
    void aGrantThatNeverSettlesFails() {
        table.items.put("bob@example.com", new HashMap<>(Map.of("email", AttributeValue.fromS("bob@example.com"),
                "roles", AttributeValue.fromS("viewer"))));
        var flips = new Runnable() {
            int n;

            @Override
            public void run() {
                table.items.get("bob@example.com").put("roles", AttributeValue.fromS("v" + (++n)));
                table.beforeSet = this;
            }
        };
        table.beforeSet = flips;
        assertThrows(IllegalStateException.class,
                () -> UserRoles.grant(table, "roles", "bob@example.com", Set.of(Roles.USER)));
    }

    @Test
    void theLockoutCountsMissesInAWindow() {
        var lockout = UserRoles.lockout(table, "roles", 3, Duration.ofHours(1));
        var start = Instant.parse("2026-10-06T10:00:00Z");
        assertFalse(lockout.locked("eve@example.com", start));
        for (var i = 0; i < 3; i++) {
            lockout.miss("eve@example.com", start.plusSeconds(i));
        }
        assertTrue(lockout.locked("eve@example.com", start.plusSeconds(10)));
        // Its roles are untouched: none declared.
        assertEquals(Set.of(), UserRoles.declared(table, "roles", "eve@example.com"));
        // The window ends; a new miss starts another.
        var later = start.plus(Duration.ofHours(1)).plusSeconds(1);
        assertFalse(lockout.locked("eve@example.com", later));
        lockout.miss("eve@example.com", later);
        assertEquals("1", table.items.get("eve@example.com").get("voucherMisses").n());
        assertFalse(lockout.locked("eve@example.com", later));
    }
}
