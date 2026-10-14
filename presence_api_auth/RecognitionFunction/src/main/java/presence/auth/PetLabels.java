package presence.auth;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * A cat's or dog's breed and coat, from its {@link Siglip2} embedding: the
 * likeliest of its species' breeds (a softmax over them, as SigLIP2 compares
 * a picture with captions), shown from {@link #BREED_SURE}, and of its
 * coats, from {@link #COAT_SURE}. The labels and their text embeddings are
 * {@code pet-labels.tsv} and {@code pet-labels.bin}, made by
 * {@code tools/pet_labels.py}. Some breeds are picked but never shown
 * ({@code none}): house cats and mixed breeds, and breeds told apart by a
 * coat or a tail (a Bombay is a black cat to a camera; the coat says it).
 * On the Oxford-IIIT pets this showed a breed on 64 % of them, right 98 %
 * of the time; on 72 house cats, 1 breed (specs/cloud-recognition.md).
 * Breeds are tagged with their species ("Persian cat", "Poodle dog").
 *
 * <p>First, which animal it is ({@code animal} labels, of species
 * {@code any}): the detector has no class for a ferret or a rabbit (a
 * ferret is a cat or a dog to it), so one of those, from
 * {@link #ANIMAL_SURE}, is tagged ("ferret") and its coat looked for
 * among its own ("sable ferret"). A cat stays a cat and a dog a dog: the
 * detector tells those apart better.
 */
final class PetLabels {

    /** SigLIP2's embedding length. */
    static final int DIMENSIONS = 768;

    /** SigLIP2 base's logit scale (exp of its learned log). */
    static final double SCALE = 112.6689;

    static final double BREED_SURE = 0.7;
    static final double COAT_SURE = 0.6;
    static final double ANIMAL_SURE = 0.8;

    /**
     * The least share the picture gives the detector's cat or dog for it to
     * get a breed or coat: a black cat the detector called a dog was a
     * "black dog" on 46 of 47 pictures, 3 with this (and still a "black
     * cat" on 42 of 47 called a cat).
     */
    static final double AGREE = 0.5;

    static final String CAT = "cat";
    static final String DOG = "dog";
    static final String ANY = "any";

    /**
     * One label: its species ({@code any} for an animal), type ({@code animal}, {@code breed}, {@code coat} or
     * {@code none}), what it says, and its text embedding.
     */
    record Label(String species, String type, String label, float[] vector) {
    }

    /** A label a crop has, and how sure (0 to 1). */
    record Found(String label, String type, double confidence) {
    }

    static final List<Label> LABELS = load();

    private PetLabels() {
    }

    /** "cat" or "dog"; null otherwise. */
    static String species(Object value) {
        return CAT.equals(value) || DOG.equals(value) ? (String) value : null;
    }

    /** A {@code species}' crop's labels (embedding {@code vector}): its breed and coat, those sure enough. */
    static List<Found> describe(float[] vector, String detected) {
        var out = new ArrayList<Found>();
        var species = detected;
        var animal = likeliest(vector, ANY, "animal");
        if (animal != null && !animal.label().equals(CAT) && !animal.label().equals(DOG)
                && animal.confidence() >= ANIMAL_SURE) {
            out.add(animal);
            species = animal.label();
        } else if (share(vector, detected) < AGREE) {
            // The picture doesn't agree it's the detector's cat or dog: no
            // breed, no coat, rather than a cat's "black dog".
            return out;
        }
        var breed = likeliest(vector, species, "breed", "none");
        if (breed != null && !breed.type().equals("none") && breed.confidence() >= BREED_SURE) {
            out.add(breed);
        }
        var coat = likeliest(vector, species, "coat");
        if (coat != null && coat.confidence() >= COAT_SURE) {
            out.add(coat);
        }
        return out;
    }

    /** {@code animal}'s share of a softmax over the animals ({@code any}'s {@code animal} labels). */
    private static double share(float[] vector, String animal) {
        var animals = LABELS.stream()
                .filter(l -> l.species().equals(ANY) && l.type().equals("animal"))
                .toList();
        var logits = new double[animals.size()];
        var max = Double.NEGATIVE_INFINITY;
        for (var i = 0; i < logits.length; i++) {
            logits[i] = SCALE * Vectors.dot(animals.get(i).vector(), vector);
            max = Math.max(max, logits[i]);
        }
        var sum = 0.0;
        var mine = 0.0;
        for (var i = 0; i < logits.length; i++) {
            var e = Math.exp(logits[i] - max);
            sum += e;
            if (animals.get(i).label().equals(animal)) {
                mine = e;
            }
        }
        return sum == 0 ? 0 : mine / sum;
    }

    /** The likeliest of {@code species}' labels of {@code types}, and its share of a softmax over them. */
    private static Found likeliest(float[] vector, String species, String... types) {
        var kinds = Arrays.asList(types);
        var candidates = LABELS.stream()
                .filter(l -> l.species().equals(species) && kinds.contains(l.type()))
                .toList();
        if (candidates.isEmpty()) {
            return null;
        }
        var logits = new double[candidates.size()];
        var best = 0;
        for (var i = 0; i < logits.length; i++) {
            logits[i] = SCALE * Vectors.dot(candidates.get(i).vector(), vector);
            if (logits[i] > logits[best]) {
                best = i;
            }
        }
        var sum = 0.0;
        for (var logit : logits) {
            sum += Math.exp(logit - logits[best]);
        }
        var label = candidates.get(best);
        return new Found(label.label(), label.type(), 1 / sum);
    }

    private static List<Label> load() {
        try (var tsv = PetLabels.class.getResourceAsStream("pet-labels.tsv");
             var bin = PetLabels.class.getResourceAsStream("pet-labels.bin")) {
            if (tsv == null || bin == null) {
                throw new IllegalStateException("pet-labels.tsv or pet-labels.bin is missing");
            }
            var lines = new String(tsv.readAllBytes(), StandardCharsets.UTF_8).lines()
                    .filter(l -> !l.isBlank()).toList();
            var vectors = bin.readAllBytes();
            if (vectors.length != lines.size() * DIMENSIONS * 4) {
                throw new IllegalStateException("pet-labels.bin doesn't match pet-labels.tsv");
            }
            var out = new ArrayList<Label>();
            for (var i = 0; i < lines.size(); i++) {
                var f = lines.get(i).split("\t");
                var at = i * DIMENSIONS * 4;
                out.add(new Label(f[0], f[1], f[2],
                        Vectors.fromBytes(Arrays.copyOfRange(vectors, at, at + DIMENSIONS * 4), DIMENSIONS)));
            }
            return List.copyOf(out);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
