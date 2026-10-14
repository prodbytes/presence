package presence.auth;

import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Optional;
import java.util.regex.Pattern;

/**
 * Presence sessions' refresh tokens: opaque, 256 random bits ({@code
 * prt_<43 base64url>}), kept only as their SHA-256 with the identity they
 * sign in, for {@link #REFRESH_FOR} after their last use (sliding).
 * <ul>
 *   <li><b>Rotated on every use:</b> a refresh answers a new refresh token
 *       and uses the old one up.</li>
 *   <li><b>Reuse is theft:</b> each sign-in starts a <i>family</i>, which
 *       every token rotated from it belongs to. A used token presented
 *       again (someone kept a copy) revokes its whole family, so neither
 *       the thief nor the app keeps the session; the app then signs in
 *       again (Google quietly where it can). Except within {@link #GRACE}
 *       of its use: an app whose refresh answer was lost (a timeout after
 *       the rotation) retries with the same token, and gets another new
 *       one rather than losing its session.</li>
 *   <li><b>Revoked</b> at sign-out ({@link #revoke}), and every family of
 *       an identity at once when its account is deleted ({@link
 *       #revokeAll}).</li>
 * </ul>
 * The session tokens already issued stay valid until they expire (an
 * hour): they're verified offline by every API.
 */
final class Sessions {

    /** How long a refresh token lasts unused; each refresh starts it over. */
    static final Duration REFRESH_FOR = Duration.ofDays(60);

    static final Pattern REFRESH_TOKEN = Pattern.compile("prt_[A-Za-z0-9_-]{43}");

    /** How long after its use a refresh token may be used again (a retry), not counting as reuse. */
    static final Duration GRACE = Duration.ofSeconds(60);

    /** Who a session signs in: what its tokens say. */
    record Who(String idp, String idpSub, String email, String name, String picture, String hd) {

        String subject() {
            return Profiles.subject(idp, idpSub);
        }
    }

    /** A refresh token's record: its family, who, when it was used up (null: not yet), and until when it works. */
    record Token(String family, Who who, Instant usedAt, Instant expiresAt) {

        boolean used() {
            return usedAt != null;
        }
    }

    /** A sign-in's family of refresh tokens. */
    record Family(String id, String subject, boolean revoked, Instant expiresAt) {
    }

    /** A new refresh token and who it signs in. */
    record Issued(String refreshToken, Who who) {
    }

    /** Where refresh tokens and their families are kept (DynamoDB: {@link DynamoSessions}). */
    interface Store {
        /** Saves a new family and its first token (by its hash). */
        void start(Family family, String tokenHash, Token token);

        Optional<Token> token(String hash);

        Optional<Family> family(String id);

        /**
         * Atomically: uses up {@code oldHash} at {@code now} (only if it
         * isn't used yet, or was used after {@code usedAfter}: a retry within
         * the grace), saves {@code next} under {@code nextHash} and extends the
         * family to {@code until} (only if it isn't revoked). False if either
         * condition failed: nothing changed.
         */
        boolean rotate(String oldHash, String nextHash, Token next, Instant until, Instant now, Instant usedAfter);

        void revoke(String family);

        /** The families of {@code subject} (account deletion). */
        List<String> families(String subject);
    }

    private final Store store;
    private final SecureRandom random;
    private final Clock clock;

    Sessions(Store store, SecureRandom random, Clock clock) {
        this.store = store;
        this.random = random;
        this.clock = clock;
    }

    /** A new session's first refresh token for {@code who}. */
    String start(Who who) {
        var family = HexFormat.of().formatHex(bytes(16));
        var until = clock.instant().plus(REFRESH_FOR);
        var raw = newToken();
        store.start(new Family(family, who.subject(), false, until), ProfileHandler.hash(raw),
                new Token(family, who, null, until));
        return raw;
    }

    /**
     * Trades {@code raw} for a new refresh token: empty if it's malformed,
     * unknown, expired, used or revoked. A used one revokes its family.
     */
    Optional<Issued> refresh(String raw) {
        if (raw == null || !REFRESH_TOKEN.matcher(raw).matches()) {
            return Optional.empty();
        }
        var hash = ProfileHandler.hash(raw);
        var now = clock.instant();
        var token = store.token(hash).orElse(null);
        if (token == null || !token.expiresAt().isAfter(now)) {
            return Optional.empty();
        }
        var family = store.family(token.family()).orElse(null);
        if (family == null || family.revoked()) {
            return Optional.empty();
        }
        var usedAfter = now.minus(GRACE);
        if (token.used() && !token.usedAt().isAfter(usedAfter)) {
            reused(token.family());
            return Optional.empty();
        }
        var next = newToken();
        var until = now.plus(REFRESH_FOR);
        if (!store.rotate(hash, ProfileHandler.hash(next), new Token(token.family(), token.who(), null, until),
                until, now, usedAfter)) {
            // Used meanwhile (two refreshes with one token), or revoked.
            reused(token.family());
            return Optional.empty();
        }
        return Optional.of(new Issued(next, token.who()));
    }

    /** Ends {@code raw}'s session (sign-out): its whole family. Unknown tokens are ignored. */
    void revoke(String raw) {
        if (raw == null || !REFRESH_TOKEN.matcher(raw).matches()) {
            return;
        }
        store.token(ProfileHandler.hash(raw)).ifPresent(t -> store.revoke(t.family()));
    }

    /** Ends every session of {@code subject} ({@code <idp>#<sub>}): its account is being deleted. */
    void revokeAll(String subject) {
        for (var family : store.families(subject)) {
            store.revoke(family);
        }
    }

    private void reused(String family) {
        System.err.println("presence: a used refresh token was presented again; its session ("
                + family.substring(0, Math.min(8, family.length())) + "…) is revoked");
        store.revoke(family);
    }

    private String newToken() {
        return "prt_" + Base64.getUrlEncoder().withoutPadding().encodeToString(bytes(32));
    }

    private byte[] bytes(int n) {
        var bytes = new byte[n];
        random.nextBytes(bytes);
        return bytes;
    }
}
