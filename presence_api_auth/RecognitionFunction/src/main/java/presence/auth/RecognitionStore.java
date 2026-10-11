package presence.auth;

import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Each profile's labels (their crops' embeddings, never the crops) and its
 * trained model: the recognition table in AWS, a map in tests.
 */
interface RecognitionStore {

    /** What a training left: when, from how many labels, and the subjects learned. */
    record Model(long trainedAt, int labels, List<Classifier.Subject> subjects) {
    }

    /** Every label of {@code profile}. */
    List<Classifier.Label> labels(String profile);

    /** Adds or replaces a label. */
    void putLabel(String profile, Classifier.Label label);

    void deleteLabel(String profile, String id);

    /** The profile's model; null if it was never trained. */
    Model model(String profile);

    void putModel(String profile, Model model);

    /**
     * The table {@code table}: key {@code profile} (the profile ID) and
     * {@code item}: {@code label#<id>} ({@code clipId}, {@code name}, {@code kind},
     * {@code labeledAt}, {@code vector}: 1024 float32s) and {@code model}
     * ({@code trainedAt}, {@code labels}, {@code subjects}: a list of
     * {@code {name, kind, labels, bias, weights}}).
     */
    static RecognitionStore dynamo(DynamoDbClient db, String table) {
        return new RecognitionStore() {
            private static final String LABEL = "label#";
            private static final String MODEL = "model";

            private Map<String, AttributeValue> key(String profile, String item) {
                return Map.of("profile", s(profile), "item", s(item));
            }

            @Override
            public List<Classifier.Label> labels(String profile) {
                var out = new ArrayList<Classifier.Label>();
                var pages = db.queryPaginator(q -> q.tableName(table)
                        .keyConditionExpression("#p = :p AND begins_with(#i, :l)")
                        .expressionAttributeNames(Map.of("#p", "profile", "#i", "item"))
                        .expressionAttributeValues(Map.of(":p", s(profile), ":l", s(LABEL)))
                        .consistentRead(true));
                for (var item : pages.items()) {
                    var vector = Vectors.fromBytes(bytes(item.get("vector")), Embedder.DIMENSIONS);
                    var kind = Classifier.kind(string(item.get("kind")));
                    var name = string(item.get("name"));
                    if (vector == null || kind == null || name == null) {
                        continue;
                    }
                    out.add(new Classifier.Label(string(item.get("item")).substring(LABEL.length()),
                            string(item.get("clipId")), name, kind, number(item.get("labeledAt")), vector));
                }
                return out;
            }

            @Override
            public void putLabel(String profile, Classifier.Label label) {
                var item = new HashMap<>(key(profile, LABEL + label.id()));
                item.put("name", s(label.name()));
                if (label.clipId() != null) {
                    item.put("clipId", s(label.clipId()));
                }
                item.put("kind", s(label.kind()));
                item.put("labeledAt", n(label.labeledAt()));
                item.put("vector", AttributeValue.fromB(SdkBytes.fromByteArray(Vectors.toBytes(label.vector()))));
                db.putItem(p -> p.tableName(table).item(item));
            }

            @Override
            public void deleteLabel(String profile, String id) {
                db.deleteItem(d -> d.tableName(table).key(key(profile, LABEL + id)));
            }

            @Override
            public Model model(String profile) {
                var item = db.getItem(g -> g.tableName(table).key(key(profile, MODEL)).consistentRead(true)).item();
                if (item == null || item.isEmpty()) {
                    return null;
                }
                var subjects = new ArrayList<Classifier.Subject>();
                var list = item.get("subjects");
                if (list != null && list.hasL()) {
                    for (var entry : list.l()) {
                        var m = entry.m();
                        var weights = Vectors.fromBytes(bytes(m.get("weights")), Embedder.DIMENSIONS);
                        var kind = Classifier.kind(string(m.get("kind")));
                        if (weights == null || kind == null || string(m.get("name")) == null) {
                            continue;
                        }
                        subjects.add(new Classifier.Subject(string(m.get("name")), kind,
                                (int) number(m.get("labels")), weights, (float) Double.parseDouble(m.get("bias").n())));
                    }
                }
                return new Model(number(item.get("trainedAt")), (int) number(item.get("labels")), subjects);
            }

            @Override
            public void putModel(String profile, Model model) {
                var subjects = new ArrayList<AttributeValue>();
                for (var s : model.subjects()) {
                    subjects.add(AttributeValue.fromM(Map.of(
                            "name", s(s.name()),
                            "kind", s(s.kind()),
                            "labels", n(s.labels()),
                            "bias", AttributeValue.fromN(Float.toString(s.bias())),
                            "weights", AttributeValue.fromB(SdkBytes.fromByteArray(Vectors.toBytes(s.weights()))))));
                }
                var item = new HashMap<>(key(profile, MODEL));
                item.put("trainedAt", n(model.trainedAt()));
                item.put("labels", n(model.labels()));
                item.put("subjects", AttributeValue.fromL(subjects));
                db.putItem(p -> p.tableName(table).item(item));
            }

            private static AttributeValue s(String value) {
                return AttributeValue.fromS(value);
            }

            private static AttributeValue n(long value) {
                return AttributeValue.fromN(Long.toString(value));
            }

            private static String string(AttributeValue value) {
                return value == null ? null : value.s();
            }

            private static long number(AttributeValue value) {
                try {
                    return value == null || value.n() == null ? 0 : Long.parseLong(value.n());
                } catch (NumberFormatException e) {
                    return 0;
                }
            }

            private static byte[] bytes(AttributeValue value) {
                return value == null || value.b() == null ? null : value.b().asByteArray();
            }
        };
    }
}
