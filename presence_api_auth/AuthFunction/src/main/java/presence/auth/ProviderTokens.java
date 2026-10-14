package presence.auth;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.Signature;
import java.time.Clock;
import java.time.Duration;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Verifies the ID token a sign-in provider gave the app, before {@link
 * SessionHandler} trades it for a Presence session: Google's (as the HTTP
 * API's JWT authorizer did before sessions) and Apple's (Sign in with
 * Apple). Every check must hold, or the token is {@link Refused}:
 * <ul>
 *   <li>RS256 (no other algorithm, no {@code crit}), signed by a key of the
 *       provider's JWKS, found by its {@code kid};</li>
 *   <li>{@code iss} the provider's ({@code https://accounts.google.com}, or
 *       {@code accounts.google.com}, which some Google clients send;
 *       {@code https://appleid.apple.com});</li>
 *   <li>{@code aud} one of the configured clients (Google: the web client,
 *       which every platform's app asks tokens for, and the streamer's
 *       device client; Apple: the app's bundle ID);</li>
 *   <li>{@code exp} in the future, {@code iat} and {@code nbf} (when
 *       present) not, each with a minute of clock skew;</li>
 *   <li>a {@code sub}, and an {@code email} the provider verified ({@code
 *       email_verified}: Apple's private-relay addresses are verified
 *       too);</li>
 *   <li>Apple: {@code nonce} is the SHA-256 (hex) of the nonce the app
 *       sent with the exchange, which the app made for this sign-in, so a
 *       token taken from somewhere else can't be replayed here.</li>
 * </ul>
 */
final class ProviderTokens {

    static final String GOOGLE = "https://accounts.google.com";
    static final String APPLE = "https://appleid.apple.com";

    static final URI GOOGLE_KEYS = URI.create("https://www.googleapis.com/oauth2/v3/certs");
    static final URI APPLE_KEYS = URI.create("https://appleid.apple.com/auth/keys");

    static final Duration SKEW = Duration.ofSeconds(60);

    /** Who signed in, as the provider says. */
    record Identity(String idp, String sub, String email, String name, String picture, String hd,
                    String audience) {

        /** The identity's key: {@code <idp>#<sub>}, as profiles link subjects ({@link Profiles#subject}). */
        String subject() {
            return Profiles.subject(idp, sub);
        }
    }

    /** The token isn't one to trust; the reason is for the log, never the caller. */
    static class Refused extends Exception {
        Refused(String reason) {
            super(reason);
        }
    }

    private final Jwks googleKeys;
    private final Set<String> googleAudiences;
    private final Jwks appleKeys;
    private final Set<String> appleAudiences;
    private final Clock clock;

    ProviderTokens(Jwks googleKeys, Set<String> googleAudiences, Jwks appleKeys, Set<String> appleAudiences,
                   Clock clock) {
        this.googleKeys = googleKeys;
        this.googleAudiences = googleAudiences;
        this.appleKeys = appleKeys;
        this.appleAudiences = appleAudiences;
        this.clock = clock;
    }

    /** From the environment: {@code GOOGLE_AUDIENCES} and {@code APPLE_AUDIENCES}, comma-separated. */
    static ProviderTokens fromEnvironment() {
        var clock = Clock.systemUTC();
        var http = Jwks.http();
        return new ProviderTokens(new Jwks(GOOGLE_KEYS, http, clock), list(System.getenv("GOOGLE_AUDIENCES")),
                new Jwks(APPLE_KEYS, http, clock), list(System.getenv("APPLE_AUDIENCES")), clock);
    }

    /** A comma-separated list, trimmed, without empty entries. */
    static Set<String> list(String value) {
        return value == null ? Set.of() : Arrays.stream(value.split(","))
                .map(String::strip).filter(s -> !s.isEmpty()).collect(Collectors.toUnmodifiableSet());
    }

    /** Whether {@code provider} ({@code google} or {@code apple}) has any client configured. */
    boolean configured(String provider) {
        return switch (provider) {
            case "google" -> !googleAudiences.isEmpty();
            case "apple" -> !appleAudiences.isEmpty();
            default -> false;
        };
    }

    /**
     * The identity in {@code idToken} from {@code provider}, after every
     * check above; {@code nonce} is the app's raw nonce (Apple's).
     */
    Identity verify(String provider, String idToken, String nonce) throws Refused {
        var apple = "apple".equals(provider);
        if (!apple && !"google".equals(provider)) {
            throw new Refused("unknown provider");
        }
        Jwt jwt;
        try {
            jwt = Jwt.parse(idToken);
        } catch (IllegalArgumentException e) {
            throw new Refused("not a JWT");
        }
        var header = jwt.header();
        if (!"RS256".equals(header.get("alg")) || header.containsKey("crit")) {
            throw new Refused("not RS256");
        }
        var kid = Jwt.text(header, "kid");
        if (kid == null) {
            throw new Refused("no kid");
        }
        var key = (apple ? appleKeys : googleKeys).key(kid).orElseThrow(() -> new Refused("unknown kid"));
        try {
            var verifier = Signature.getInstance("SHA256withRSA");
            verifier.initVerify(key);
            verifier.update(jwt.signingInput());
            if (!verifier.verify(jwt.signature())) {
                throw new Refused("bad signature");
            }
        } catch (GeneralSecurityException e) {
            throw new Refused("bad signature");
        }
        var claims = jwt.claims();
        var iss = Jwt.text(claims, "iss");
        if (apple ? !APPLE.equals(iss) : !(GOOGLE.equals(iss) || "accounts.google.com".equals(iss))) {
            throw new Refused("wrong issuer");
        }
        var audience = audience(claims.get("aud"));
        if (audience == null || !(apple ? appleAudiences : googleAudiences).contains(audience)) {
            throw new Refused("wrong audience");
        }
        var now = clock.instant().getEpochSecond();
        var exp = Jwt.seconds(claims, "exp");
        if (exp == null || now >= exp + SKEW.toSeconds()) {
            throw new Refused("expired");
        }
        for (var claim : List.of("iat", "nbf")) {
            var at = Jwt.seconds(claims, claim);
            if (at != null && at > now + SKEW.toSeconds()) {
                throw new Refused(claim + " in the future");
            }
        }
        var sub = Jwt.text(claims, "sub");
        if (sub == null || sub.isBlank() || sub.length() > 255) {
            throw new Refused("no subject");
        }
        if (apple) {
            var sent = Jwt.text(claims, "nonce");
            if (nonce == null || nonce.isBlank() || sent == null
                    || !MessageDigest.isEqual(sha256Hex(nonce).getBytes(StandardCharsets.US_ASCII),
                    sent.getBytes(StandardCharsets.US_ASCII))) {
                throw new Refused("wrong nonce");
            }
        }
        var email = Jwt.text(claims, "email");
        if (email == null || !ProfileHandler.validEmail(email.strip().toLowerCase(Locale.ROOT))
                || !"true".equalsIgnoreCase(Jwt.text(claims, "email_verified"))) {
            throw new UnverifiedEmail();
        }
        var hd = apple ? null : Jwt.text(claims, "hd");
        return new Identity(apple ? APPLE : GOOGLE, sub, email.strip(), apple ? null : Jwt.text(claims, "name"),
                apple ? null : Jwt.text(claims, "picture"), hd == null ? null : hd.toLowerCase(Locale.ROOT),
                audience);
    }

    /** A token without a verified email: signed in, but not someone Presence can know (403, not 401). */
    static final class UnverifiedEmail extends Refused {
        UnverifiedEmail() {
            super("no verified email");
        }
    }

    /** {@code aud}: a string, or an array of exactly one. */
    private static String audience(Object aud) {
        if (aud instanceof String s) {
            return s;
        }
        if (aud instanceof List<?> list && list.size() == 1 && list.getFirst() instanceof String s) {
            return s;
        }
        return null;
    }

    /** SHA-256 of {@code text} (UTF-8), lowercase hex: how the app hashes Apple's nonce. */
    static String sha256Hex(String text) {
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
