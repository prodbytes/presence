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

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class UserRolesTest {

    /**
     * The UserRoles table, evaluating just the update and condition
     * expressions {@link UserRoles} sends, as DynamoDB would.
     */
    private static final class Table implements DynamoDbClient {
        final Map<String, Map<String, AttributeValue>> items = new HashMap<>();
        final List<String> updates = new ArrayList<>();

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
            updates.add(request.updateExpression());
            switch (request.updateExpression()) {
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
    void theLockoutCountsMissesInAWindow() {
        var lockout = UserRoles.lockout(table, "roles", 3, Duration.ofHours(1));
        var start = Instant.parse("2026-10-06T10:00:00Z");
        assertFalse(lockout.locked("eve@example.com", start));
        for (var i = 0; i < 3; i++) {
            lockout.miss("eve@example.com", start.plusSeconds(i));
        }
        assertTrue(lockout.locked("eve@example.com", start.plusSeconds(10)));
        // Just the counters: roles live in rbacr.
        assertEquals(Set.of("email", "voucherMisses", "voucherMissesSince"), table.items.get("eve@example.com").keySet());
        // The window ends; a new miss starts another.
        var later = start.plus(Duration.ofHours(1)).plusSeconds(1);
        assertFalse(lockout.locked("eve@example.com", later));
        lockout.miss("eve@example.com", later);
        assertEquals("1", table.items.get("eve@example.com").get("voucherMisses").n());
        assertFalse(lockout.locked("eve@example.com", later));
    }
}
