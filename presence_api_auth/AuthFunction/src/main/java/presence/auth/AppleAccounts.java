package presence.auth;

import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.services.kms.KmsClient;
import software.amazon.awssdk.services.kms.model.DecryptRequest;
import software.amazon.awssdk.services.kms.model.EncryptRequest;
import software.amazon.awssdk.services.ssm.SsmClient;
import software.amazon.awssdk.services.ssm.model.GetParameterRequest;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Clock;
import java.time.Duration;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.Supplier;
import java.util.stream.Collectors;

/**
 * Sign in with Apple's server side, for one duty: Apple requires an app
 * that offers Sign in with Apple to revoke the user's Apple tokens when
 * they delete their account ({@code https://appleid.apple.com/auth/revoke}).
 * <ul>
 *   <li>At an Apple sign-in, when the app sends its authorization code and
 *       the stack has Apple's key ({@code APPLE_TEAM_ID}, {@code
 *       APPLE_KEY_ID} and the {@code .p8} in the SSM SecureString {@code
 *       APPLE_KEY_PARAMETER}), {@link #keep} trades the code at {@code
 *       /auth/token} for Apple's refresh token and keeps it, encrypted with
 *       the stack's KMS data key (the identity as encryption context), with
 *       the identity ({@link Identities}). A failure is logged and the
 *       sign-in goes on: the session doesn't depend on it.</li>
 *   <li>{@link #revoke} (account deletion) decrypts it, revokes it at Apple
 *       and forgets it.</li>
 *   <li>Each call to Apple carries a client secret: an ES256 JWT signed with
 *       the {@code .p8} ({@code iss} the team, {@code sub} the client,
 *       {@code aud} Apple, five minutes).</li>
 * </ul>
 * Neither the key, the code nor any token is ever logged.
 */
final class AppleAccounts {

    static final URI TOKEN = URI.create("https://appleid.apple.com/auth/token");
    static final URI REVOKE = URI.create("https://appleid.apple.com/auth/revoke");
    static final Duration TIMEOUT = Duration.ofSeconds(3);

    /** POSTs a form; the status and body. */
    @FunctionalInterface
    interface Transport {
        Reply post(URI uri, String form) throws Exception;
    }

    record Reply(int status, String body) {
    }

    /** Encrypts a secret for one identity, and back (KMS, the identity as encryption context). */
    interface Sealer {
        String seal(String plain, String subject);

        String open(String sealed, String subject);
    }

    /** Apple's key: the team, the key's ID and the key ({@code .p8}), read when first needed. */
    record Key(String teamId, String keyId, Supplier<PrivateKey> privateKey) {
    }

    private final Key key;
    private final Identities identities;
    private final Sealer sealer;
    private final Transport transport;
    private final Clock clock;

    /** @param key null when the stack has no Apple key: nothing is kept or revoked */
    AppleAccounts(Key key, Identities identities, Sealer sealer, Transport transport, Clock clock) {
        this.key = key;
        this.identities = identities;
        this.sealer = sealer;
        this.transport = transport;
        this.clock = clock;
    }

    /**
     * From the environment ({@code APPLE_TEAM_ID}, {@code APPLE_KEY_ID},
     * {@code APPLE_KEY_PARAMETER}, {@code DATA_KEY_ARN}); without all four,
     * not configured.
     */
    static AppleAccounts fromEnvironment(Identities identities) {
        var team = env("APPLE_TEAM_ID");
        var keyId = env("APPLE_KEY_ID");
        var parameter = env("APPLE_KEY_PARAMETER");
        var dataKey = env("DATA_KEY_ARN");
        if (team == null || keyId == null || parameter == null || dataKey == null) {
            return new AppleAccounts(null, identities, null, null, Clock.systemUTC());
        }
        var http = Aws.http();
        var ssm = SsmClient.builder().httpClient(http).build();
        var kms = KmsClient.builder().httpClient(http).build();
        Supplier<PrivateKey> privateKey = new Supplier<>() {
            private PrivateKey cached;

            @Override
            public synchronized PrivateKey get() {
                if (cached == null) {
                    cached = privateKey(ssm.getParameter(GetParameterRequest.builder()
                            .name(parameter).withDecryption(true).build()).parameter().value());
                }
                return cached;
            }
        };
        return new AppleAccounts(new Key(team, keyId, privateKey), identities, kms(kms, dataKey), http(),
                Clock.systemUTC());
    }

    private static String env(String name) {
        var value = System.getenv(name);
        return value == null || value.isBlank() ? null : value.strip();
    }

    boolean configured() {
        return key != null;
    }

    /**
     * Trades the authorization {@code code} of {@code subject}'s Apple
     * sign-in (for {@code clientId}) for Apple's refresh token, and keeps it
     * encrypted. Best effort: false (logged) if it couldn't.
     */
    boolean keep(String subject, String clientId, String code) {
        if (key == null || code == null || code.isBlank()) {
            return false;
        }
        try {
            var reply = transport.post(TOKEN, form(Map.of(
                    "client_id", clientId,
                    "client_secret", clientSecret(clientId),
                    "code", code,
                    "grant_type", "authorization_code")));
            if (reply.status() != 200) {
                System.err.println("presence: Apple's token endpoint answered HTTP " + reply.status()
                        + error(reply.body()));
                return false;
            }
            var refresh = Jwt.text(Jwt.object(reply.body().getBytes(StandardCharsets.UTF_8)), "refresh_token");
            if (refresh == null || refresh.isBlank()) {
                System.err.println("presence: Apple's token endpoint answered no refresh token");
                return false;
            }
            identities.saveAppleToken(subject, clientId, sealer.seal(refresh, subject), clock.instant());
            return true;
        } catch (Exception e) {
            System.err.println("presence: could not keep the Apple refresh token: " + e.getClass().getSimpleName());
            return false;
        }
    }

    /**
     * Revokes {@code subject}'s Apple refresh token at Apple, and forgets
     * it. True when it's revoked, or there's none to revoke (another
     * provider, or kept before the stack had Apple's key); false if Apple
     * couldn't be told (then it's kept, to try again).
     */
    boolean revoke(String subject) {
        var identity = identities.get(subject).orElse(null);
        if (identity == null || identity.appleRefreshToken() == null) {
            return true;
        }
        if (key == null) {
            System.err.println("presence: an Apple refresh token can't be revoked: the stack has no Apple key");
            return false;
        }
        try {
            var reply = transport.post(REVOKE, form(Map.of(
                    "client_id", identity.appleClientId(),
                    "client_secret", clientSecret(identity.appleClientId()),
                    "token", sealer.open(identity.appleRefreshToken(), subject),
                    "token_type_hint", "refresh_token")));
            if (reply.status() != 200) {
                System.err.println("presence: Apple's revoke endpoint answered HTTP " + reply.status()
                        + error(reply.body()));
                return false;
            }
            identities.clearAppleToken(subject);
            return true;
        } catch (Exception e) {
            System.err.println("presence: could not revoke the Apple refresh token: " + e.getClass().getSimpleName());
            return false;
        }
    }

    /** Apple's client secret for {@code clientId}: an ES256 JWT, valid five minutes. */
    String clientSecret(String clientId) throws GeneralSecurityException {
        var now = clock.instant().getEpochSecond();
        var header = new LinkedHashMap<String, Object>();
        header.put("alg", "ES256");
        header.put("kid", key.keyId());
        var claims = new LinkedHashMap<String, Object>();
        claims.put("iss", key.teamId());
        claims.put("iat", now);
        claims.put("exp", now + 300);
        claims.put("aud", "https://appleid.apple.com");
        claims.put("sub", clientId);
        var input = Jwt.base64(Jwt.json(header).getBytes(StandardCharsets.UTF_8)) + "."
                + Jwt.base64(Jwt.json(claims).getBytes(StandardCharsets.UTF_8));
        var signer = Signature.getInstance("SHA256withECDSA");
        signer.initSign(key.privateKey().get());
        signer.update(input.getBytes(StandardCharsets.US_ASCII));
        return input + "." + Jwt.base64(joseSignature(signer.sign()));
    }

    /** A {@code .p8} (PKCS #8 PEM) as an EC private key. */
    static PrivateKey privateKey(String pem) {
        var base64 = pem.replaceAll("-----(BEGIN|END) PRIVATE KEY-----", "").replaceAll("\\s", "");
        try {
            return KeyFactory.getInstance("EC").generatePrivate(new PKCS8EncodedKeySpec(Base64.getDecoder().decode(base64)));
        } catch (GeneralSecurityException | IllegalArgumentException e) {
            throw new IllegalStateException("the Apple key isn't a PKCS #8 EC key");
        }
    }

    /** A DER ECDSA signature (SEQUENCE of r and s) as JWS wants it: r and s, 32 bytes each. */
    static byte[] joseSignature(byte[] der) {
        var out = new byte[64];
        var offset = 2;
        if ((der[1] & 0x80) != 0) {
            offset += der[1] & 0x7f;
        }
        for (var part = 0; part < 2; part++) {
            if (der[offset] != 0x02) {
                throw new IllegalArgumentException("not a DER signature");
            }
            var length = der[offset + 1];
            var start = offset + 2;
            var copy = Math.min(length, 32);
            System.arraycopy(der, start + length - copy, out, part * 32 + 32 - copy, copy);
            offset = start + length;
        }
        return out;
    }

    private static String form(Map<String, String> fields) {
        return fields.entrySet().stream()
                .map(e -> URLEncoder.encode(e.getKey(), StandardCharsets.UTF_8) + "="
                        + URLEncoder.encode(e.getValue(), StandardCharsets.UTF_8))
                .collect(Collectors.joining("&"));
    }

    /** Apple's {@code error} code, for the log (never the body, which may hold tokens). */
    private static String error(String body) {
        try {
            var code = Jwt.text(Jwt.object(body.getBytes(StandardCharsets.UTF_8)), "error");
            return code == null || !code.matches("[a-z_]{1,64}") ? "" : " (" + code + ")";
        } catch (RuntimeException e) {
            return "";
        }
    }

    /** The JDK's HTTP client, within {@link #TIMEOUT}. */
    static Transport http() {
        var client = HttpClient.newBuilder().connectTimeout(TIMEOUT).build();
        return (uri, form) -> {
            var response = client.send(HttpRequest.newBuilder(uri)
                            .timeout(TIMEOUT)
                            .header("content-type", "application/x-www-form-urlencoded")
                            .POST(HttpRequest.BodyPublishers.ofString(form, StandardCharsets.UTF_8))
                            .build(),
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            return new Reply(response.statusCode(), response.body());
        };
    }

    /** KMS with the stack's data key, the identity as encryption context. */
    static Sealer kms(KmsClient kms, String keyId) {
        return new Sealer() {
            @Override
            public String seal(String plain, String subject) {
                return Base64.getEncoder().encodeToString(kms.encrypt(EncryptRequest.builder()
                        .keyId(keyId)
                        .plaintext(SdkBytes.fromUtf8String(plain))
                        .encryptionContext(Map.of("subject", subject))
                        .build()).ciphertextBlob().asByteArray());
            }

            @Override
            public String open(String sealed, String subject) {
                return kms.decrypt(DecryptRequest.builder()
                        .keyId(keyId)
                        .ciphertextBlob(SdkBytes.fromByteArray(Base64.getDecoder().decode(sealed)))
                        .encryptionContext(Map.of("subject", subject))
                        .build()).plaintext().asUtf8String();
            }
        };
    }
}
