package presence.auth;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.HexFormat;
import java.util.LinkedHashMap;

/**
 * Mints Presence session tokens: RS256 JWTs signed by {@link
 * SessionSigner}, which every Presence API's JWT authorizer (audience
 * {@link #AUDIENCE}, issuer {@code SESSION_ISSUER}) and rbacr accept.
 * <ul>
 *   <li>{@code iss}: {@code https://<site>/api/auth} (per stage), whose
 *       {@code /.well-known/openid-configuration} names the JWKS;</li>
 *   <li>{@code aud}: {@code presence};</li>
 *   <li>{@code sub}: a stable Presence subject for the provider identity
 *       ({@link #subjectOf}), never the provider's own;</li>
 *   <li>{@code idp} and {@code idp_sub}: the provider's issuer and subject,
 *       which find the identity's profile ({@code <idp>#<idp_sub>}, the
 *       key profiles always had);</li>
 *   <li>{@code email} (verified by the provider: {@code email_verified} is
 *       always true), {@code name} and {@code picture} when known, and
 *       {@code hd} (Google Workspace's domain) when Google gave one;</li>
 *   <li>{@code iat} and {@code exp}: {@link #LIFETIME}.</li>
 * </ul>
 */
final class SessionTokens {

    static final String AUDIENCE = "presence";

    static final Duration LIFETIME = Duration.ofHours(1);

    /** A minted token and when it expires. */
    record Minted(String token, Instant expiresAt) {
    }

    private final SessionSigner signer;
    private final String issuer;
    private final Clock clock;

    SessionTokens(SessionSigner signer, String issuer, Clock clock) {
        this.signer = signer;
        this.issuer = issuer;
        this.clock = clock;
    }

    String issuer() {
        return issuer;
    }

    SessionSigner signer() {
        return signer;
    }

    /** A token for {@code who}. */
    Minted mint(Sessions.Who who) {
        var now = clock.instant().getEpochSecond();
        var exp = now + LIFETIME.toSeconds();
        var header = new LinkedHashMap<String, Object>();
        header.put("alg", "RS256");
        header.put("kid", signer.kid());
        header.put("typ", "JWT");
        var claims = new LinkedHashMap<String, Object>();
        claims.put("iss", issuer);
        claims.put("aud", AUDIENCE);
        claims.put("sub", subjectOf(who.idp(), who.idpSub()));
        claims.put("iat", now);
        claims.put("exp", exp);
        claims.put("email", who.email());
        claims.put("email_verified", true);
        if (who.name() != null && !who.name().isBlank()) {
            claims.put("name", who.name());
        }
        if (who.picture() != null && !who.picture().isBlank()) {
            claims.put("picture", who.picture());
        }
        if (who.hd() != null && !who.hd().isBlank()) {
            claims.put("hd", who.hd());
        }
        claims.put("idp", who.idp());
        claims.put("idp_sub", who.idpSub());
        var input = Jwt.base64(Jwt.json(header).getBytes(StandardCharsets.UTF_8)) + "."
                + Jwt.base64(Jwt.json(claims).getBytes(StandardCharsets.UTF_8));
        var signature = signer.sign(input.getBytes(StandardCharsets.US_ASCII));
        return new Minted(input + "." + Jwt.base64(signature), Instant.ofEpochSecond(exp));
    }

    /**
     * The Presence subject of a provider identity: {@code p_} and the first
     * 32 hex digits of SHA-256 of {@code <idp>#<sub>}. Stable, the same on
     * every device, and it says nothing of the provider's own ID.
     */
    static String subjectOf(String idp, String sub) {
        try {
            var digest = MessageDigest.getInstance("SHA-256")
                    .digest(Profiles.subject(idp, sub).getBytes(StandardCharsets.UTF_8));
            return "p_" + HexFormat.of().formatHex(digest, 0, 16);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    /** {@code /.well-known/openid-configuration}: enough for API Gateway's JWT authorizer and rbacr. */
    String discovery() {
        var document = new LinkedHashMap<String, Object>();
        document.put("issuer", issuer);
        document.put("jwks_uri", issuer + "/.well-known/jwks.json");
        document.put("id_token_signing_alg_values_supported", java.util.List.of("RS256"));
        document.put("subject_types_supported", java.util.List.of("public"));
        document.put("response_types_supported", java.util.List.of("id_token"));
        document.put("claims_supported", java.util.List.of("iss", "aud", "sub", "iat", "exp", "email",
                "email_verified", "name", "picture", "hd", "idp", "idp_sub"));
        return Jwt.json(document);
    }

    /** {@code /.well-known/jwks.json}: the signing key's public half. */
    String jwks() {
        return Jwt.json(java.util.Map.of("keys", java.util.List.of(signer.jwk())));
    }
}
