package presence.auth;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * A profile's subjects, learned from their labels' embeddings: one logistic
 * regression per subject (one against the rest). A subject's own labels are
 * its positives; its negatives are the other subjects' labels of the same
 * sort (people, or pets) and {@link #NEGATIVES}, people, cats and dogs
 * nobody knows, so a profile with one subject still learns what isn't them.
 * Class-balanced, L2-regularized ({@link #LAMBDA}), on embeddings scaled to
 * length {@link #SCALE}, by gradient descent with Nesterov momentum. On one
 * black cat against 18 others, in places she was never labeled, this ranked
 * her above them with an AUC of 0.91 (nearest neighbour: 0.75).
 */
final class Classifier {

    static final double LAMBDA = 0.3;
    static final int ITERATIONS = 300;
    static final double RATE = 0.5;
    static final double MOMENTUM = 0.9;
    static final double SCALE = 32;

    /** The most subjects learned, those with the most labels. */
    static final int MAX_SUBJECTS = 50;

    /** People and pets (cats and dogs are both pets: the detector mixes them up). */
    static final String PERSON = "person";
    static final String PET = "pet";

    /**
     * A label someone placed: who ({@code name}), what sort, when, the clip
     * it's on (null if not sent), and its crop's embedding.
     */
    record Label(String id, String clipId, String name, String kind, long labeledAt, float[] vector) {
    }

    /** A learned subject: its name as on its latest label, its sort, its label count, and its weights. */
    record Subject(String name, String kind, int labels, float[] weights, float bias) {

        /** How sure it is that {@code vector} is this subject, from 0 to 1. */
        double probability(float[] vector) {
            return 1 / (1 + Math.exp(-(SCALE * Vectors.dot(weights, vector) + bias)));
        }
    }

    /** Unknown people (kind {@link #PERSON}) and pets ({@link #PET}): COCO val2017's, as embedded by {@link Dinov2}. */
    static final Map<String, List<float[]>> NEGATIVES = negatives();

    private Classifier() {
    }

    /** "person", or "pet" for a cat, a dog or a pet; null otherwise. */
    static String kind(Object value) {
        if (!(value instanceof String s)) {
            return null;
        }
        return switch (s.toLowerCase(Locale.ROOT)) {
            case "person", "human" -> PERSON;
            case "pet", "cat", "dog" -> PET;
            default -> null;
        };
    }

    /** A subject's identity: its name, ignoring case and surrounding spaces (as the app's). */
    static String subjectId(String name) {
        return name.strip().toLowerCase(Locale.ROOT);
    }

    /** Learns every subject in {@code labels} (up to {@link #MAX_SUBJECTS}). */
    static List<Subject> train(List<Label> labels) {
        var bySubject = new LinkedHashMap<String, List<Label>>();
        for (var label : labels) {
            bySubject.computeIfAbsent(subjectId(label.name()), k -> new ArrayList<>()).add(label);
        }
        var subjects = new ArrayList<>(bySubject.values());
        subjects.sort(Comparator.comparingInt((List<Label> l) -> -l.size()));
        var learned = new ArrayList<Subject>();
        for (var own : subjects.subList(0, Math.min(MAX_SUBJECTS, subjects.size()))) {
            var latest = own.stream().max(Comparator.comparingLong(Label::labeledAt)).orElseThrow();
            var kind = majorityKind(own);
            var id = subjectId(latest.name());
            var positives = own.stream().map(Label::vector).toList();
            var negatives = new ArrayList<>(NEGATIVES.getOrDefault(kind, List.of()));
            for (var label : labels) {
                if (!subjectId(label.name()).equals(id) && kind.equals(label.kind())) {
                    negatives.add(label.vector());
                }
            }
            learned.add(fit(latest.name().strip(), kind, positives, negatives));
        }
        return learned;
    }

    private static String majorityKind(List<Label> labels) {
        var people = labels.stream().filter(l -> PERSON.equals(l.kind())).count();
        return people * 2 >= labels.size() ? PERSON : PET;
    }

    /** One subject's regression: {@code positives} against {@code negatives}. */
    static Subject fit(String name, String kind, List<float[]> positives, List<float[]> negatives) {
        var n = positives.size() + negatives.size();
        var d = Embedder.DIMENSIONS;
        var x = new float[n][];
        var y = new double[n];
        var weight = new double[n];
        var i = 0;
        for (var v : positives) {
            x[i] = v;
            y[i] = 1;
            weight[i++] = n / (2.0 * positives.size());
        }
        for (var v : negatives) {
            x[i] = v;
            weight[i++] = negatives.isEmpty() ? 0 : n / (2.0 * negatives.size());
        }
        var w = new double[d];
        var velocity = new double[d];
        double b = 0;
        double vb = 0;
        var lookahead = new double[d];
        var gradient = new double[d];
        for (var step = 0; step < ITERATIONS; step++) {
            for (var j = 0; j < d; j++) {
                lookahead[j] = w[j] + MOMENTUM * velocity[j];
            }
            var lb = b + MOMENTUM * vb;
            java.util.Arrays.fill(gradient, 0);
            double gb = 0;
            for (var k = 0; k < n; k++) {
                var row = x[k];
                double z = lb;
                for (var j = 0; j < d; j++) {
                    z += SCALE * row[j] * lookahead[j];
                }
                var g = weight[k] * (1 / (1 + Math.exp(-z)) - y[k]) / n;
                gb += g;
                var gs = g * SCALE;
                for (var j = 0; j < d; j++) {
                    gradient[j] += gs * row[j];
                }
            }
            for (var j = 0; j < d; j++) {
                velocity[j] = MOMENTUM * velocity[j] - RATE * (gradient[j] + LAMBDA * lookahead[j]) / SCALE;
                w[j] += velocity[j];
            }
            vb = MOMENTUM * vb - RATE * gb;
            b += vb;
        }
        var weights = new float[d];
        for (var j = 0; j < d; j++) {
            weights[j] = (float) w[j];
        }
        return new Subject(name, kind, positives.size(), weights, (float) b);
    }

    /**
     * The resource {@code negatives.bin}: records of a sort byte (0 a
     * person, 1 a pet) and 1024 float16s, little-endian.
     */
    private static Map<String, List<float[]>> negatives() {
        try (var in = Classifier.class.getResourceAsStream("negatives.bin")) {
            if (in == null) {
                throw new IllegalStateException("negatives.bin is missing");
            }
            var bytes = in.readAllBytes();
            var record = 1 + 2 * Embedder.DIMENSIONS;
            var out = new HashMap<String, List<float[]>>();
            for (var at = 0; at + record <= bytes.length; at += record) {
                var v = new float[Embedder.DIMENSIONS];
                for (var j = 0; j < v.length; j++) {
                    var lo = bytes[at + 1 + 2 * j] & 0xff;
                    var hi = bytes[at + 2 + 2 * j] & 0xff;
                    v[j] = Float.float16ToFloat((short) (lo | hi << 8));
                }
                out.computeIfAbsent(bytes[at] == 0 ? PERSON : PET, k -> new ArrayList<>()).add(v);
            }
            return out;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
