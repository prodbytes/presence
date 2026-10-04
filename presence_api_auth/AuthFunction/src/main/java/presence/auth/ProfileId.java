package presence.auth;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.util.List;
import java.util.Random;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * A profile's ID: two different adjectives and an animal, joined by underscores,
 * such as {@code automatic_paranoid_axolotl}. Like the app's device IDs
 * ({@code automatic_paranoid_gadget}), with the same 1053 adjectives, and
 * 1031 animals ({@code adjectives.txt}, {@code animals.txt}): about 1.1
 * billion IDs. Random IDs alone could repeat, so {@link Profiles} only
 * keeps one that no profile has yet.
 */
public final class ProfileId {

    static final List<String> ADJECTIVES = words("adjectives.txt");
    static final List<String> ANIMALS = words("animals.txt");

    /** What an ID looks like: {@code adjective_adjective_animal}, lowercase. */
    static final Pattern PATTERN = Pattern.compile("[a-z]+_[a-z]+_[a-z]+");

    private static final Set<String> ADJECTIVE_SET = Set.copyOf(ADJECTIVES);
    private static final Set<String> ANIMAL_SET = Set.copyOf(ANIMALS);

    private static final Random SECURE = new SecureRandom();

    private ProfileId() {
    }

    /** How many different IDs {@link #generate} can make. */
    static long combinations() {
        return (long) ADJECTIVES.size() * (ADJECTIVES.size() - 1) * ANIMALS.size();
    }

    /** A new random ID, from a cryptographically secure generator. */
    public static String generate() {
        return generate(SECURE);
    }

    static String generate(Random random) {
        var first = random.nextInt(ADJECTIVES.size());
        // Two different adjectives: pick the second from the others.
        var second = random.nextInt(ADJECTIVES.size() - 1);
        if (second >= first) {
            second++;
        }
        return ADJECTIVES.get(first) + "_" + ADJECTIVES.get(second) + "_"
                + ANIMALS.get(random.nextInt(ANIMALS.size()));
    }

    /**
     * Whether {@code id} is one {@link #generate} could make: two different
     * adjectives and an animal from the lists. The app makes its own, so
     * anything else it sends is refused.
     */
    public static boolean valid(String id) {
        if (id == null || id.length() > 100 || !PATTERN.matcher(id).matches()) {
            return false;
        }
        var parts = id.split("_");
        return !parts[0].equals(parts[1]) && ADJECTIVE_SET.contains(parts[0])
                && ADJECTIVE_SET.contains(parts[1]) && ANIMAL_SET.contains(parts[2]);
    }

    private static List<String> words(String resource) {
        try (var in = ProfileId.class.getResourceAsStream(resource)) {
            if (in == null) {
                throw new IllegalStateException("missing " + resource);
            }
            return new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8)).lines()
                    .map(String::strip)
                    .filter(w -> !w.isEmpty())
                    .toList();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
