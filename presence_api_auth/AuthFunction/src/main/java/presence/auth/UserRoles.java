package presence.auth;

import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;

/**
 * The UserRoles table, one item per (lowercase) email. It once declared
 * roles; rbacr keeps them now ({@link Rbacr}), and
 * scripts/migrate-roles-to-rbacr.sh copied its {@code roles} there. What's
 * left: the email's recent wrong voucher codes ({@code voucherMisses},
 * counted since {@code voucherMissesSince}, epoch ms) for
 * {@link VoucherHandler.Lockout}.
 */
final class UserRoles {

    private UserRoles() {
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
