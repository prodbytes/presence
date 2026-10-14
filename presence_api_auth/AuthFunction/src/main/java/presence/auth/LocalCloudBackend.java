package presence.auth;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.util.Base64;
import java.util.Optional;
import java.util.UUID;

/**
 * The local stack's backend ({@code LOCAL_CLOUD=true}, set only by
 * presence_floci's init): Floci, the local AWS, has no Cognito Identity
 * ({@code GetId}, {@code GetOpenIdTokenForDeveloperIdentity}, {@code
 * GetCredentialsForIdentity}), so this stands in for it. Link codes and
 * the bucket stay {@code aws}'s (Floci's DynamoDB and S3).
 * <ul>
 *   <li>A profile's identity is made up from its ID:
 *       {@code <region>:<UUID of "presence-local|profile#<id>">}, the same on
 *       every call, as Cognito's would be.</li>
 *   <li>The credentials route answers {@link #credentials credentials}
 *       itself, random ones for an hour, which the app uses as it would
 *       Cognito's: Floci doesn't check them.</li>
 *   <li>Live sync needs no IoT policy: Floci's broker lets anyone in.</li>
 * </ul>
 * Never in AWS: the identities and credentials are fake, and nothing here
 * enforces the tier.
 */
final class LocalCloudBackend implements ProfileHandler.Backend {

    /** How long the made-up credentials are said to last, as Cognito's. */
    static final Duration CREDENTIALS_FOR = Duration.ofHours(1);


    private final ProfileHandler.Backend aws;
    private final String region;
    private final SecureRandom random;
    private final Clock clock;

    LocalCloudBackend(ProfileHandler.Backend aws, String region, SecureRandom random, Clock clock) {
        this.aws = aws;
        this.region = region == null || region.isBlank() ? "us-east-1" : region.strip();
        this.random = random;
        this.clock = clock;
    }

    /** Whether the function runs in the local stack ({@code LOCAL_CLOUD=true}). */
    static boolean enabled() {
        return "true".equalsIgnoreCase(System.getenv("LOCAL_CLOUD"));
    }

    static LocalCloudBackend fromEnvironment(ProfileHandler.Backend aws) {
        System.out.println("presence: LOCAL_CLOUD: made-up identities and credentials (the local stack only)");
        return new LocalCloudBackend(aws, System.getenv("AWS_REGION"), new SecureRandom(), Clock.systemUTC());
    }

    @Override
    public void saveCode(String hash, ProfileHandler.LinkCode code) {
        aws.saveCode(hash, code);
    }

    @Override
    public Optional<ProfileHandler.LinkCode> peekCode(String hash, java.time.Instant now) {
        return aws.peekCode(hash, now);
    }

    @Override
    public Optional<ProfileHandler.LinkCode> takeCode(String hash, java.time.Instant now) {
        return aws.takeCode(hash, now);
    }

    /** The profile's identity, made up from its ID: the same on every call, as Cognito's would be. */
    @Override
    public String newIdentity(String profileId) {
        return identityOf(region, "profile", profileId);
    }

    /** {@code <region>:<UUID>}, as Cognito's identity IDs look. */
    static String identityOf(String region, String iss, String sub) {
        var name = "presence-local|" + iss + "#" + sub;
        return region + ":" + UUID.nameUUIDFromBytes(name.getBytes(StandardCharsets.UTF_8));
    }

    /** No token to trade: the credentials come with the answer ({@link #credentials}). */
    @Override
    public String openIdToken(String identityId, String profileId) {
        return "local";
    }

    @Override
    public void saveStreamKey(String profileId, String deviceId, ProfileHandler.StreamKey key) {
        aws.saveStreamKey(profileId, deviceId, key);
    }

    @Override
    public Optional<ProfileHandler.StreamKey> streamKey(String profileId, String deviceId) {
        return aws.streamKey(profileId, deviceId);
    }

    @Override
    public void deleteStreamKey(String profileId, String deviceId) {
        aws.deleteStreamKey(profileId, deviceId);
    }

    @Override
    public boolean folderEmpty(String identityId) {
        return aws.folderEmpty(identityId);
    }

    @Override
    public void allowLiveSync(String identityId) {
        // Floci's broker has no policies.
    }

    /**
     * Credentials in Cognito's {@code GetCredentialsForIdentity} shape
     * ({@code AccessKeyId}, {@code SecretKey}, {@code SessionToken},
     * {@code Expiration} in epoch seconds): random, which Floci takes.
     */
    @Override
    public Optional<String> credentials(String identityId) {
        var expiration = clock.instant().plus(CREDENTIALS_FOR).getEpochSecond();
        return Optional.of("{\"AccessKeyId\":" + Json.string("ASIALOCAL" + token(8).toUpperCase())
                + ",\"SecretKey\":" + Json.string(token(30))
                + ",\"SessionToken\":" + Json.string(token(48))
                + ",\"Expiration\":" + expiration + "}");
    }

    private String token(int bytes) {
        var raw = new byte[bytes];
        random.nextBytes(raw);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(raw).replace('-', 'x').replace('_', 'y');
    }
}
