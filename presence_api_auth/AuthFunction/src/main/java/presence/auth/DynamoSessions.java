package presence.auth;

import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.Put;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItem;
import software.amazon.awssdk.services.dynamodb.model.TransactWriteItemsRequest;
import software.amazon.awssdk.services.dynamodb.model.TransactionCanceledException;
import software.amazon.awssdk.services.dynamodb.model.Update;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static presence.auth.Attrs.text;

/**
 * {@link Sessions.Store} and {@link Identities} in DynamoDB.
 * <ul>
 *   <li>{@code SessionsTable} ({@code id}): refresh tokens as {@code
 *       t#<SHA-256>} ({@code family}, who: {@code idp}, {@code idpSub},
 *       {@code email}, {@code name}, {@code picture}, {@code hd}; {@code
 *       usedAt} epoch ms, {@code expiresAt} epoch s, the TTL) and their families as
 *       {@code f#<id>} ({@code familySubject}, indexed by {@code subject}
 *       for account deletion; {@code revoked}, {@code expiresAt}).</li>
 *   <li>{@code IdentitiesTable} ({@code subject}, {@code <idp>#<sub>}):
 *       {@code name}, {@code appleClientId}, {@code appleRefreshToken}
 *       (KMS ciphertext, base64), {@code updatedAt} epoch ms.</li>
 * </ul>
 */
final class DynamoSessions implements Sessions.Store, Identities {

    private final DynamoDbClient dynamo;
    private final String sessions;
    private final String identities;

    DynamoSessions(DynamoDbClient dynamo, String sessions, String identities) {
        this.dynamo = dynamo;
        this.sessions = sessions;
        this.identities = identities;
    }

    static DynamoSessions fromEnvironment() {
        return new DynamoSessions(Aws.dynamo(), System.getenv("SESSIONS_TABLE"), System.getenv("IDENTITIES_TABLE"));
    }

    private static Map<String, AttributeValue> key(String id) {
        return Map.of("id", AttributeValue.fromS(id));
    }

    private static AttributeValue seconds(Instant at) {
        return AttributeValue.fromN(Long.toString(at.getEpochSecond()));
    }

    private static Map<String, AttributeValue> tokenItem(String hash, Sessions.Token token) {
        var item = new HashMap<String, AttributeValue>();
        item.put("id", AttributeValue.fromS("t#" + hash));
        item.put("family", AttributeValue.fromS(token.family()));
        var who = token.who();
        item.put("idp", AttributeValue.fromS(who.idp()));
        item.put("idpSub", AttributeValue.fromS(who.idpSub()));
        item.put("email", AttributeValue.fromS(who.email()));
        putIfSet(item, "name", who.name());
        putIfSet(item, "picture", who.picture());
        putIfSet(item, "hd", who.hd());
        if (token.usedAt() != null) {
            item.put("usedAt", Attrs.millis(token.usedAt()));
        }
        item.put("expiresAt", seconds(token.expiresAt()));
        return item;
    }

    private static void putIfSet(Map<String, AttributeValue> item, String name, String value) {
        if (value != null && !value.isBlank()) {
            item.put(name, AttributeValue.fromS(value));
        }
    }

    @Override
    public void start(Sessions.Family family, String tokenHash, Sessions.Token token) {
        dynamo.transactWriteItems(TransactWriteItemsRequest.builder().transactItems(
                TransactWriteItem.builder().put(Put.builder().tableName(sessions).item(Map.of(
                        "id", AttributeValue.fromS("f#" + family.id()),
                        "familySubject", AttributeValue.fromS(family.subject()),
                        "revoked", AttributeValue.fromBool(false),
                        "expiresAt", seconds(family.expiresAt())))
                        .conditionExpression("attribute_not_exists(id)").build()).build(),
                TransactWriteItem.builder().put(Put.builder().tableName(sessions).item(tokenItem(tokenHash, token))
                        .conditionExpression("attribute_not_exists(id)").build()).build()).build());
    }

    @Override
    public Optional<Sessions.Token> token(String hash) {
        var item = dynamo.getItem(GetItemRequest.builder().tableName(sessions).key(key("t#" + hash))
                .consistentRead(true).build()).item();
        if (item == null || item.isEmpty()) {
            return Optional.empty();
        }
        var who = new Sessions.Who(text(item, "idp"), text(item, "idpSub"), text(item, "email"),
                blankToNull(text(item, "name")), blankToNull(text(item, "picture")), blankToNull(text(item, "hd")));
        var usedAt = item.get("usedAt") == null ? null : Attrs.instant(item.get("usedAt"));
        return Optional.of(new Sessions.Token(text(item, "family"), who, usedAt, epoch(item.get("expiresAt"))));
    }

    @Override
    public Optional<Sessions.Family> family(String id) {
        var item = dynamo.getItem(GetItemRequest.builder().tableName(sessions).key(key("f#" + id))
                .consistentRead(true).build()).item();
        if (item == null || item.isEmpty()) {
            return Optional.empty();
        }
        var revoked = item.get("revoked") != null && Boolean.TRUE.equals(item.get("revoked").bool());
        return Optional.of(new Sessions.Family(id, text(item, "familySubject"), revoked,
                epoch(item.get("expiresAt"))));
    }

    @Override
    public boolean rotate(String oldHash, String nextHash, Sessions.Token next, Instant until, Instant now,
                          Instant usedAfter) {
        try {
            dynamo.transactWriteItems(TransactWriteItemsRequest.builder().transactItems(
                    TransactWriteItem.builder().update(Update.builder().tableName(sessions).key(key("t#" + oldHash))
                            // The first use's time stays: the grace runs from it.
                            .updateExpression("SET usedAt = if_not_exists(usedAt, :now)")
                            .conditionExpression("attribute_exists(id) AND "
                                    + "(attribute_not_exists(usedAt) OR usedAt > :after)")
                            .expressionAttributeValues(Map.of(":now", Attrs.millis(now),
                                    ":after", Attrs.millis(usedAfter)))
                            .build()).build(),
                    TransactWriteItem.builder().put(Put.builder().tableName(sessions).item(tokenItem(nextHash, next))
                            .conditionExpression("attribute_not_exists(id)").build()).build(),
                    TransactWriteItem.builder().update(Update.builder().tableName(sessions)
                            .key(key("f#" + next.family()))
                            .updateExpression("SET expiresAt = :until")
                            .conditionExpression("attribute_exists(id) AND revoked = :no")
                            .expressionAttributeValues(Map.of(":until", seconds(until),
                                    ":no", AttributeValue.fromBool(false)))
                            .build()).build()).build());
            return true;
        } catch (TransactionCanceledException e) {
            return false;
        }
    }

    @Override
    public void revoke(String family) {
        try {
            dynamo.updateItem(UpdateItemRequest.builder().tableName(sessions).key(key("f#" + family))
                    .updateExpression("SET revoked = :yes")
                    .conditionExpression("attribute_exists(id)")
                    .expressionAttributeValues(Map.of(":yes", AttributeValue.fromBool(true)))
                    .build());
        } catch (ConditionalCheckFailedException e) {
            // Gone already (expired by TTL): nothing to revoke.
        }
    }

    @Override
    public List<String> families(String subject) {
        var families = new ArrayList<String>();
        Map<String, AttributeValue> start = null;
        do {
            var page = dynamo.query(QueryRequest.builder().tableName(sessions).indexName("subject")
                    .keyConditionExpression("familySubject = :s")
                    .expressionAttributeValues(Map.of(":s", AttributeValue.fromS(subject)))
                    .exclusiveStartKey(start)
                    .build());
            for (var item : page.items()) {
                var id = text(item, "id");
                if (id.startsWith("f#")) {
                    families.add(id.substring(2));
                }
            }
            start = page.lastEvaluatedKey() == null || page.lastEvaluatedKey().isEmpty() ? null
                    : page.lastEvaluatedKey();
        } while (start != null);
        return families;
    }

    @Override
    public Optional<Identities.Identity> get(String subject) {
        var item = dynamo.getItem(GetItemRequest.builder().tableName(identities)
                .key(Map.of("subject", AttributeValue.fromS(subject))).consistentRead(true).build()).item();
        if (item == null || item.isEmpty()) {
            return Optional.empty();
        }
        return Optional.of(new Identities.Identity(subject, blankToNull(text(item, "name")),
                blankToNull(text(item, "appleClientId")), blankToNull(text(item, "appleRefreshToken"))));
    }

    @Override
    public void saveName(String subject, String name, Instant at) {
        dynamo.updateItem(UpdateItemRequest.builder().tableName(identities)
                .key(Map.of("subject", AttributeValue.fromS(subject)))
                .updateExpression("SET #n = :name, updatedAt = :at")
                .expressionAttributeNames(Map.of("#n", "name"))
                .expressionAttributeValues(Map.of(":name", AttributeValue.fromS(name), ":at", Attrs.millis(at)))
                .build());
    }

    @Override
    public void saveAppleToken(String subject, String clientId, String encrypted, Instant at) {
        dynamo.updateItem(UpdateItemRequest.builder().tableName(identities)
                .key(Map.of("subject", AttributeValue.fromS(subject)))
                .updateExpression("SET appleClientId = :client, appleRefreshToken = :token, updatedAt = :at")
                .expressionAttributeValues(Map.of(":client", AttributeValue.fromS(clientId),
                        ":token", AttributeValue.fromS(encrypted), ":at", Attrs.millis(at)))
                .build());
    }

    @Override
    public void clearAppleToken(String subject) {
        try {
            dynamo.updateItem(UpdateItemRequest.builder().tableName(identities)
                    .key(Map.of("subject", AttributeValue.fromS(subject)))
                    .updateExpression("REMOVE appleClientId, appleRefreshToken")
                    .conditionExpression("attribute_exists(subject)")
                    .build());
        } catch (ConditionalCheckFailedException e) {
            // No such identity: nothing to forget.
        }
    }

    @Override
    public void delete(String subject) {
        dynamo.deleteItem(DeleteItemRequest.builder().tableName(identities)
                .key(Map.of("subject", AttributeValue.fromS(subject))).build());
    }

    private static Instant epoch(AttributeValue value) {
        try {
            return Instant.ofEpochSecond(Long.parseLong(value.n()));
        } catch (NumberFormatException | NullPointerException e) {
            return Instant.EPOCH;
        }
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value;
    }
}
