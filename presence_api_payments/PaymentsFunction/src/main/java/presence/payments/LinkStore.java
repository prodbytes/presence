package presence.payments;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

import java.util.Map;
import java.util.Optional;

/** Where the links admins save are kept. */
interface LinkStore {

    /** The links an admin saved, if any. */
    Optional<PaymentLinks> load();

    /** Saves {@code links}, replacing what was saved. */
    void save(PaymentLinks links);

    /**
     * The payments table ({@code PAYMENTS_TABLE}): one item, {@code {"id":
     * "links", "monthly", "yearly", "updatedAt" (epoch ms), "updatedBy"}}.
     */
    static LinkStore dynamo(String table) {
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create()).build();
        var key = Map.of("id", AttributeValue.fromS("links"));
        return new LinkStore() {
            @Override
            public Optional<PaymentLinks> load() {
                var item = dynamo.getItem(r -> r.tableName(table).key(key).consistentRead(true)).item();
                if (item == null || item.isEmpty()) {
                    return Optional.empty();
                }
                return Optional.of(new PaymentLinks(text(item, "monthly"), text(item, "yearly"),
                        Long.parseLong(item.getOrDefault("updatedAt", AttributeValue.fromN("1")).n()),
                        item.containsKey("updatedBy") ? item.get("updatedBy").s() : null));
            }

            @Override
            public void save(PaymentLinks links) {
                dynamo.putItem(r -> r.tableName(table).item(Map.of(
                        "id", AttributeValue.fromS("links"),
                        "monthly", AttributeValue.fromS(links.monthly()),
                        "yearly", AttributeValue.fromS(links.yearly()),
                        "updatedAt", AttributeValue.fromN(Long.toString(links.updatedAt())),
                        "updatedBy", AttributeValue.fromS(links.updatedBy()))));
            }

            private static String text(Map<String, AttributeValue> item, String name) {
                var value = item.get(name);
                return value == null || value.s() == null ? "" : value.s();
            }
        };
    }
}
