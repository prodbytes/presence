package presence.payments;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Store purchases and who they belong to, in the payments table:
 * <ul>
 *   <li>{@code account:<email>}: the account's {@code accountToken} (a
 *       random UUID the app puts on its purchases: Apple's {@code
 *       appAccountToken}, Google's {@code obfuscatedAccountId}), its
 *       {@code purchases} (keys of the items below) and {@code
 *       grantedUntil}, the end of the rbacr grant it made last (epoch ms);</li>
 *   <li>{@code purchase:ios:<originalTransactionId>} and {@code
 *       purchase:android:<SHA-256 of the purchase token>}: the {@code email}
 *       it's bound to (once bound, never another), {@code productId},
 *       {@code expiresAt} (epoch ms), {@code revoked}, {@code updatedAt}.</li>
 * </ul>
 */
interface PurchaseStore {

    /** A purchase bound to an account, as the store said last ({@code signedAt}). */
    record Binding(String key, String email, String productId, Instant expiresAt, boolean revoked,
                   Instant signedAt) {
    }

    /**
     * What {@link #bind} did: bound to {@code email} (the caller's, or
     * another's: nothing changed), and whether what it was given was older
     * than what's there ({@code stale}: nothing changed either).
     */
    record Bound(String email, boolean stale) {
    }

    /** The account's token, made (once) on first use. */
    String accountToken(String email);

    /**
     * Binds the purchase {@code key} to {@code email} with what the store
     * said at {@code signedAt}, or updates it when it's bound to {@code
     * email} already and nothing newer was recorded.
     */
    Bound bind(String email, String key, String productId, Instant expiresAt, boolean revoked, Instant signedAt,
               Instant now);

    /** The purchase {@code key}'s binding, if it has one. */
    Optional<Binding> binding(String key);

    /** The purchases bound to {@code email}. */
    List<Binding> purchasesOf(String email);

    /** The end of the last rbacr grant made for {@code email}, or null. */
    Instant grantedUntil(String email);

    /** Records it ({@code null}: none). */
    void grantedUntil(String email, Instant until);

    /** The key of {@code purchase}'s item. */
    static String key(StorePurchase purchase) {
        return key(purchase.platform(), purchase.purchaseId());
    }

    /** The key of a purchase's item: Google's tokens are long, so they're hashed. */
    static String key(String platform, String purchaseId) {
        if (StorePurchase.IOS.equals(platform)) {
            return "purchase:ios:" + purchaseId;
        }
        try {
            return "purchase:android:" + HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256").digest(purchaseId.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** The payments table ({@code PAYMENTS_TABLE}). */
    static PurchaseStore dynamo(String table) {
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
        return new PurchaseStore() {
            private Map<String, AttributeValue> id(String id) {
                return Map.of("id", AttributeValue.fromS(id));
            }

            private Map<String, AttributeValue> get(String id) {
                var item = dynamo.getItem(r -> r.tableName(table).key(id(id)).consistentRead(true)).item();
                return item == null || item.isEmpty() ? null : item;
            }

            @Override
            public String accountToken(String email) {
                var account = get("account:" + email);
                if (account != null && account.containsKey("accountToken")) {
                    return account.get("accountToken").s();
                }
                // if_not_exists: two first calls at once agree on one token.
                return dynamo.updateItem(r -> r.tableName(table).key(id("account:" + email))
                        .updateExpression("SET #t = if_not_exists(#t, :t)")
                        .expressionAttributeNames(Map.of("#t", "accountToken"))
                        .expressionAttributeValues(Map.of(":t", AttributeValue.fromS(UUID.randomUUID().toString())))
                        .returnValues(ReturnValue.ALL_NEW)).attributes().get("accountToken").s();
            }

            @Override
            public Bound bind(String email, String key, String productId, Instant expiresAt, boolean revoked,
                              Instant signedAt, Instant now) {
                try {
                    dynamo.updateItem(r -> r.tableName(table).key(id(key))
                            .updateExpression("SET #e = :e, #p = :p, #x = :x, #r = :r, #s = :s, #u = :u")
                            // Never another account's; never an older state over a newer one.
                            .conditionExpression("(attribute_not_exists(#e) OR #e = :e)"
                                    + " AND (attribute_not_exists(#s) OR #s <= :s)")
                            .expressionAttributeNames(Map.of("#e", "email", "#p", "productId",
                                    "#x", "expiresAt", "#r", "revoked", "#s", "signedAt", "#u", "updatedAt"))
                            .expressionAttributeValues(Map.of(
                                    ":e", AttributeValue.fromS(email),
                                    ":p", AttributeValue.fromS(productId),
                                    ":x", AttributeValue.fromN(Long.toString(expiresAt.toEpochMilli())),
                                    ":r", AttributeValue.fromBool(revoked),
                                    ":s", AttributeValue.fromN(Long.toString(signedAt.toEpochMilli())),
                                    ":u", AttributeValue.fromN(Long.toString(now.toEpochMilli())))));
                } catch (ConditionalCheckFailedException e) {
                    var bound = binding(key).map(Binding::email).orElse("");
                    return new Bound(bound, bound.equals(email));
                }
                dynamo.updateItem(r -> r.tableName(table).key(id("account:" + email))
                        .updateExpression("ADD #k :k")
                        .expressionAttributeNames(Map.of("#k", "purchases"))
                        .expressionAttributeValues(Map.of(":k", AttributeValue.fromSs(List.of(key)))));
                return new Bound(email, false);
            }

            @Override
            public Optional<Binding> binding(String key) {
                var item = get(key);
                if (item == null || !item.containsKey("email")) {
                    return Optional.empty();
                }
                return Optional.of(new Binding(key, item.get("email").s(),
                        item.containsKey("productId") ? item.get("productId").s() : "",
                        Instant.ofEpochMilli(Long.parseLong(item.getOrDefault("expiresAt",
                                AttributeValue.fromN("0")).n())),
                        item.containsKey("revoked") && Boolean.TRUE.equals(item.get("revoked").bool()),
                        Instant.ofEpochMilli(Long.parseLong(item.getOrDefault("signedAt",
                                AttributeValue.fromN("0")).n()))));
            }

            @Override
            public List<Binding> purchasesOf(String email) {
                var account = get("account:" + email);
                var found = new ArrayList<Binding>();
                if (account != null && account.containsKey("purchases")) {
                    for (var key : account.get("purchases").ss()) {
                        binding(key).filter(b -> b.email().equals(email)).ifPresent(found::add);
                    }
                }
                return found;
            }

            @Override
            public Instant grantedUntil(String email) {
                var account = get("account:" + email);
                return account == null || !account.containsKey("grantedUntil") ? null
                        : Instant.ofEpochMilli(Long.parseLong(account.get("grantedUntil").n()));
            }

            @Override
            public void grantedUntil(String email, Instant until) {
                if (until == null) {
                    dynamo.updateItem(r -> r.tableName(table).key(id("account:" + email))
                            .updateExpression("REMOVE #g")
                            .expressionAttributeNames(Map.of("#g", "grantedUntil")));
                } else {
                    dynamo.updateItem(r -> r.tableName(table).key(id("account:" + email))
                            .updateExpression("SET #g = :g")
                            .expressionAttributeNames(Map.of("#g", "grantedUntil"))
                            .expressionAttributeValues(Map.of(":g",
                                    AttributeValue.fromN(Long.toString(until.toEpochMilli())))));
                }
            }
        };
    }
}
