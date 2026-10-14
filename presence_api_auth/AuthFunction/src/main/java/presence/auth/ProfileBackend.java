package presence.auth;

import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.DeleteIdentitiesRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetIdRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityResponse;
import software.amazon.awssdk.services.cognitoidentity.model.NotAuthorizedException;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.iot.IotClient;
import software.amazon.awssdk.services.iot.model.AttachPolicyRequest;
import software.amazon.awssdk.services.iot.model.DetachPolicyRequest;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.Delete;
import software.amazon.awssdk.services.s3.model.DeleteObjectsRequest;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.ObjectIdentifier;

import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

import static presence.auth.Attrs.text;

/**
 * {@link ProfileHandler.Backend} in AWS: the link-codes table (DynamoDB),
 * the identity pool (Cognito, its developer provider), the user-data
 * bucket (S3, only to see whether a folder is empty) and live sync's IoT
 * policy (AWS IoT, attached to each identity). Profiles and their subjects
 * are {@link Profiles}'.
 */
final class ProfileBackend implements ProfileHandler.Backend {

    /** The provider the app's Google ID tokens sign in to directly (the pool's SupportedLoginProviders). */
    static final String GOOGLE = "accounts.google.com";

    private final DynamoDbClient dynamo;
    private final CognitoIdentityClient cognito;
    private final S3Client s3;
    private final String codesTable;

    /** The stream keys table ({@code STREAM_KEYS_TABLE}): {@code {"device": "<profile>/<device>", "hash", "createdBy", "subject", "createdAt"}}. */
    String streamKeysTable;

    /** Cloud recognition's table ({@code RECOGNITION_TABLE}): {@code {"profile", "item"}}; null: none. */
    String recognitionTable;

    /** Feedback and Help's table ({@code FEEDBACK_TABLE}): {@code {"conversation" (identity), "sentAt", "email"}}; null: none. */
    String feedbackTable;

    /** Tells when an account deletion's time is up. */
    Clock clock = Clock.systemUTC();

    /**
     * A Cognito identity ID, {@code <region>:<UUID>}: the only prefix whose
     * folder {@link #deleteFolder} deletes, so an empty or odd one can never
     * reach the rest of the bucket.
     */
    static final Pattern IDENTITY_ID =
            Pattern.compile("[a-z]{2}(-[a-z]+)+-[0-9]+:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
    private final String identityPoolId;
    private final String developerProvider;
    private final String bucket;
    private final IotClient iot;
    private final String iotPolicy;

    /** Identities this function instance has attached the IoT policy to: not asked again while it's warm. */
    private final Set<String> liveSyncAllowed = ConcurrentHashMap.newKeySet();

    ProfileBackend(DynamoDbClient dynamo, CognitoIdentityClient cognito, S3Client s3,
                   String codesTable, String identityPoolId, String developerProvider, String bucket) {
        this(dynamo, cognito, s3, codesTable, identityPoolId, developerProvider, bucket, null, null);
    }

    /**
     * @param iot       AWS IoT's control plane, for {@code AttachPolicy}; null without live sync
     * @param iotPolicy the live-sync policy (presence_infra/identity.yaml); null or empty without live sync
     */
    ProfileBackend(DynamoDbClient dynamo, CognitoIdentityClient cognito, S3Client s3,
                   String codesTable, String identityPoolId, String developerProvider, String bucket,
                   IotClient iot, String iotPolicy) {
        this.dynamo = dynamo;
        this.cognito = cognito;
        this.s3 = s3;
        this.codesTable = codesTable;
        this.identityPoolId = identityPoolId;
        this.developerProvider = developerProvider;
        this.bucket = bucket;
        this.iot = iot;
        this.iotPolicy = iotPolicy;
    }

    /** Whether the function has an identity pool and a bucket (template parameters, empty locally). */
    static boolean configured() {
        return Settings.fromEnvironment().aws();
    }

    static ProfileBackend fromEnvironment() {
        var http = Aws.http();
        var iotPolicy = System.getenv("IOT_POLICY_NAME");
        var backend = new ProfileBackend(
                Aws.dynamo(),
                CognitoIdentityClient.builder().httpClient(http).build(),
                // Floci's S3 (the local stack) is reached path-style.
                S3Client.builder().httpClient(http).forcePathStyle(LocalCloudBackend.enabled()).build(),
                System.getenv("LINK_CODES_TABLE"),
                System.getenv("COGNITO_IDENTITY_POOL_ID"),
                System.getenv("DEVELOPER_PROVIDER"),
                System.getenv("USER_DATA_BUCKET"),
                iotPolicy == null || iotPolicy.isBlank() ? null : IotClient.builder().httpClient(http).build(),
                iotPolicy);
        backend.streamKeysTable = System.getenv("STREAM_KEYS_TABLE");
        backend.recognitionTable = blankToNull(System.getenv("RECOGNITION_TABLE"));
        backend.feedbackTable = blankToNull(System.getenv("FEEDBACK_TABLE"));
        return backend;
    }

    private static Map<String, AttributeValue> streamKeyOf(String profileId, String deviceId) {
        return Map.of("device", AttributeValue.fromS(profileId + "/" + deviceId));
    }

    @Override
    public void saveStreamKey(String profileId, String deviceId, ProfileHandler.StreamKey key) {
        var item = new java.util.HashMap<>(streamKeyOf(profileId, deviceId));
        item.put("hash", AttributeValue.fromS(key.hash()));
        item.put("createdBy", AttributeValue.fromS(key.createdBy()));
        item.put("subject", AttributeValue.fromS(key.subject()));
        item.put("createdAt", AttributeValue.fromS(key.createdAt().toString()));
        dynamo.putItem(PutItemRequest.builder().tableName(streamKeysTable).item(item).build());
    }

    @Override
    public Optional<ProfileHandler.StreamKey> streamKey(String profileId, String deviceId) {
        var item = dynamo.getItem(GetItemRequest.builder()
                .tableName(streamKeysTable)
                .key(streamKeyOf(profileId, deviceId))
                .consistentRead(true)
                .build()).item();
        if (item == null || item.isEmpty() || text(item, "hash") == null) {
            return Optional.empty();
        }
        var createdAt = text(item, "createdAt");
        return Optional.of(new ProfileHandler.StreamKey(text(item, "hash"), text(item, "createdBy"),
                text(item, "subject"), createdAt == null ? Instant.EPOCH : Instant.parse(createdAt)));
    }

    @Override
    public void deleteStreamKey(String profileId, String deviceId) {
        dynamo.deleteItem(DeleteItemRequest.builder()
                .tableName(streamKeysTable)
                .key(streamKeyOf(profileId, deviceId))
                .build());
    }

    @Override
    public void saveCode(String hash, ProfileHandler.LinkCode code) {
        dynamo.putItem(PutItemRequest.builder()
                .tableName(codesTable)
                .item(Map.of(
                        "code", AttributeValue.fromS(hash),
                        "profileId", AttributeValue.fromS(code.profileId()),
                        "createdBy", AttributeValue.fromS(code.createdBy()),
                        // Epoch seconds: the table's TTL attribute.
                        "expiresAt", AttributeValue.fromN(Long.toString(code.expiresAt().getEpochSecond()))))
                .build());
    }

    @Override
    public Optional<ProfileHandler.LinkCode> peekCode(String hash, Instant now) {
        var item = dynamo.getItem(GetItemRequest.builder()
                .tableName(codesTable)
                .key(Map.of("code", AttributeValue.fromS(hash)))
                .consistentRead(true)
                .build()).item();
        if (item == null || item.isEmpty()) {
            return Optional.empty();
        }
        var code = linkCode(item);
        // TTL deletion lags: an expired one may still be there.
        return code.expiresAt().getEpochSecond() > now.getEpochSecond() ? Optional.of(code) : Optional.empty();
    }

    @Override
    public Optional<ProfileHandler.LinkCode> takeCode(String hash, Instant now) {
        try {
            // One use: deleted as it's read. TTL deletion lags, hence the check.
            var old = dynamo.deleteItem(DeleteItemRequest.builder()
                    .tableName(codesTable)
                    .key(Map.of("code", AttributeValue.fromS(hash)))
                    .conditionExpression("expiresAt > :now")
                    .expressionAttributeValues(Map.of(":now", AttributeValue.fromN(Long.toString(now.getEpochSecond()))))
                    .returnValues(ReturnValue.ALL_OLD)
                    .build()).attributes();
            return Optional.of(linkCode(old));
        } catch (ConditionalCheckFailedException e) {
            return Optional.empty();
        }
    }

    @Override
    public String googleIdentity(String googleIdToken) {
        return cognito.getId(GetIdRequest.builder()
                .identityPoolId(identityPoolId)
                .logins(Map.of(GOOGLE, googleIdToken))
                .build()).identityId();
    }

    @Override
    public String openIdToken(String identityId, String profileId, String googleIdToken) {
        return openIdToken(identityId, profileId, googleIdToken, ProfileHandler.FREE);
    }

    @Override
    public String openIdToken(String identityId, String profileId, String googleIdToken, String tier) {
        return openIdToken(identityId, profileId, googleIdToken, tier, false);
    }

    @Override
    public String openIdToken(String identityId, String profileId, String googleIdToken, String tier,
                              boolean admin) {
        var tags = admin
                ? Map.of(ProfileHandler.TIER_TAG, tier, ProfileHandler.ADMIN_TAG, "true")
                : Map.of(ProfileHandler.TIER_TAG, tier);
        GetOpenIdTokenForDeveloperIdentityResponse result;
        try {
            // Once linked, the profile ID alone is the proof.
            result = openIdToken(identityId, Map.of(developerProvider, profileId), tags);
        } catch (NotAuthorizedException e) {
            // Not linked yet: the identity was made by Google sign-in (GetId),
            // and Cognito links another login to it only beside one it has
            // ("Logins don't match").
            if (googleIdToken == null || googleIdToken.isBlank()) {
                throw e;
            }
            result = openIdToken(identityId, Map.of(developerProvider, profileId, GOOGLE, googleIdToken), tags);
        }
        if (!identityId.equals(result.identityId())) {
            // Never hand out another folder's credentials.
            throw new IllegalStateException("Cognito answered for identity " + result.identityId()
                    + ", not " + identityId);
        }
        return result.token();
    }

    /**
     * The token, with {@code tags} as its principal tags: Cognito sets them
     * on the session of the credentials it's traded for, where IAM reads
     * them ({@code aws:PrincipalTag/tier}).
     */
    private GetOpenIdTokenForDeveloperIdentityResponse openIdToken(String identityId, Map<String, String> logins,
                                                                   Map<String, String> tags) {
        return cognito.getOpenIdTokenForDeveloperIdentity(GetOpenIdTokenForDeveloperIdentityRequest.builder()
                .identityPoolId(identityPoolId)
                .identityId(identityId)
                .logins(logins)
                .principalTags(tags)
                .build());
    }

    @Override
    public boolean folderEmpty(String identityId) {
        return s3.listObjectsV2(ListObjectsV2Request.builder()
                .bucket(bucket)
                .prefix(identityId + "/")
                .maxKeys(1)
                .build()).keyCount() == 0;
    }

    @Override
    public void allowLiveSync(String identityId) {
        if (iot == null || iotPolicy == null || iotPolicy.isBlank() || liveSyncAllowed.contains(identityId)) {
            return;
        }
        try {
            // Idempotent: attaching it again changes nothing.
            iot.attachPolicy(AttachPolicyRequest.builder()
                    .policyName(iotPolicy)
                    .target(identityId)
                    .build());
            liveSyncAllowed.add(identityId);
        } catch (RuntimeException e) {
            // Live sync is extra: the bucket still syncs everything.
            System.err.println("presence: could not attach the live-sync policy: "
                    + Aws.cause(e) + ": " + e);
        }
    }

    /**
     * Lists the folder's first 1000 objects and deletes them
     * ({@code DeleteObjects}), again until none are left or {@code deadline}
     * passes. The bucket is versioned: what's deleted stays a noncurrent
     * version until the bucket's lifecycle expires it (30 days).
     */
    @Override
    public ProfileHandler.FolderDeletion deleteFolder(String identityId, Instant deadline) {
        if (identityId == null || !IDENTITY_ID.matcher(identityId).matches()) {
            // Never a prefix that could reach other folders, or the bucket.
            throw new IllegalArgumentException("not an identity ID");
        }
        var prefix = identityId + "/";
        var deleted = 0;
        while (true) {
            var page = s3.listObjectsV2(ListObjectsV2Request.builder()
                    .bucket(bucket)
                    .prefix(prefix)
                    .maxKeys(1000)
                    .build());
            var keys = new ArrayList<ObjectIdentifier>();
            for (var object : page.contents()) {
                if (object.key() != null && object.key().startsWith(prefix)) {
                    keys.add(ObjectIdentifier.builder().key(object.key()).build());
                }
            }
            if (keys.isEmpty()) {
                return new ProfileHandler.FolderDeletion(deleted, true);
            }
            var result = s3.deleteObjects(DeleteObjectsRequest.builder()
                    .bucket(bucket)
                    .delete(Delete.builder().objects(keys).quiet(true).build())
                    .build());
            if (result.hasErrors() && !result.errors().isEmpty()) {
                var first = result.errors().getFirst();
                throw new IllegalStateException("S3 didn't delete " + result.errors().size() + " of "
                        + keys.size() + " objects: " + first.code());
            }
            deleted += keys.size();
            if (!clock.instant().isBefore(deadline)) {
                return new ProfileHandler.FolderDeletion(deleted, false);
            }
        }
    }

    /**
     * Detaches the live-sync IoT policy from the identity, then deletes it
     * from the pool ({@code DeleteIdentities}). Failures are logged with the
     * identity, to delete by hand, and answer false.
     */
    @Override
    public boolean deleteIdentity(String identityId) {
        liveSyncAllowed.remove(identityId);
        if (iot != null && iotPolicy != null && !iotPolicy.isBlank()) {
            try {
                iot.detachPolicy(DetachPolicyRequest.builder().policyName(iotPolicy).target(identityId).build());
            } catch (RuntimeException e) {
                // Not attached, or IoT failed: the identity goes anyway.
                System.err.println("presence: could not detach the live-sync policy from " + identityId + ": "
                        + Aws.cause(e) + ": " + e);
            }
        }
        try {
            var result = cognito.deleteIdentities(DeleteIdentitiesRequest.builder()
                    .identityIdsToDelete(identityId)
                    .build());
            if (result.hasUnprocessedIdentityIds() && !result.unprocessedIdentityIds().isEmpty()) {
                System.err.println("presence: Cognito didn't delete identity " + identityId + ": "
                        + result.unprocessedIdentityIds().getFirst().errorCodeAsString() + "; delete it by hand");
                return false;
            }
            return true;
        } catch (RuntimeException e) {
            System.err.println("presence: could not delete identity " + identityId + " (delete it by hand): "
                    + Aws.cause(e) + ": " + e);
            return false;
        }
    }

    @Override
    public int deleteFeedback(String identityId, String email) {
        if (feedbackTable == null) {
            return 0;
        }
        var query = QueryRequest.builder()
                .tableName(feedbackTable)
                .keyConditionExpression("#c = :c")
                .expressionAttributeNames(Map.of("#c", "conversation", "#s", "sentAt", "#e", "email"))
                .expressionAttributeValues(Map.of(":c", AttributeValue.fromS(identityId)))
                .projectionExpression("#c, #s, #e")
                .consistentRead(true)
                .build();
        var deleted = 0;
        for (var page : dynamo.queryPaginator(query)) {
            for (var item : page.items()) {
                var from = text(item, "email");
                if (email != null && (from == null || !from.strip().toLowerCase(Locale.ROOT).equals(email))) {
                    continue;
                }
                dynamo.deleteItem(DeleteItemRequest.builder()
                        .tableName(feedbackTable)
                        .key(Map.of("conversation", item.get("conversation"), "sentAt", item.get("sentAt")))
                        .build());
                deleted++;
            }
        }
        return deleted;
    }

    @Override
    public int deleteRecognition(String profileId) {
        if (recognitionTable == null) {
            return 0;
        }
        var query = QueryRequest.builder()
                .tableName(recognitionTable)
                .keyConditionExpression("#p = :p")
                .expressionAttributeNames(Map.of("#p", "profile", "#i", "item"))
                .expressionAttributeValues(Map.of(":p", AttributeValue.fromS(profileId)))
                .projectionExpression("#p, #i")
                .consistentRead(true)
                .build();
        var keys = new ArrayList<Map<String, AttributeValue>>();
        for (var page : dynamo.queryPaginator(query)) {
            for (var item : page.items()) {
                keys.add(Map.of("profile", item.get("profile"), "item", item.get("item")));
            }
        }
        return deleteAll(recognitionTable, keys);
    }

    /** The table is keyed {@code <profile>/<device>}: a scan finds the profile's (it's small). */
    @Override
    public int deleteStreamKeys(String profileId) {
        if (streamKeysTable == null || streamKeysTable.isBlank()) {
            return 0;
        }
        return deleteAll(streamKeysTable, scan(ScanRequest.builder()
                .tableName(streamKeysTable)
                .filterExpression("begins_with(#d, :p)")
                .expressionAttributeNames(Map.of("#d", "device"))
                .expressionAttributeValues(Map.of(":p", AttributeValue.fromS(profileId + "/")))
                .projectionExpression("#d")
                .consistentRead(true)
                .build(), "device"));
    }

    /** Codes are keyed by their hash: a scan finds the profile's (few, and they expire in minutes). */
    @Override
    public int deleteLinkCodes(String profileId) {
        if (codesTable == null || codesTable.isBlank()) {
            return 0;
        }
        return deleteAll(codesTable, scan(ScanRequest.builder()
                .tableName(codesTable)
                .filterExpression("#p = :p")
                .expressionAttributeNames(Map.of("#p", "profileId", "#c", "code"))
                .expressionAttributeValues(Map.of(":p", AttributeValue.fromS(profileId)))
                .projectionExpression("#c")
                .consistentRead(true)
                .build(), "code"));
    }

    /** The keys ({@code key}, the table's only key attribute) of every item {@code scan} finds. */
    private List<Map<String, AttributeValue>> scan(ScanRequest scan, String key) {
        var keys = new ArrayList<Map<String, AttributeValue>>();
        for (var page : dynamo.scanPaginator(scan)) {
            for (var item : page.items()) {
                if (item.get(key) != null) {
                    keys.add(Map.of(key, item.get(key)));
                }
            }
        }
        return keys;
    }

    /** Deletes each item by its key, one at a time (idempotent); how many. */
    private int deleteAll(String table, List<Map<String, AttributeValue>> keys) {
        for (var key : keys) {
            dynamo.deleteItem(DeleteItemRequest.builder().tableName(table).key(key).build());
        }
        return keys.size();
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }

    private static ProfileHandler.LinkCode linkCode(Map<String, AttributeValue> item) {
        Instant expiresAt;
        try {
            expiresAt = Instant.ofEpochSecond(Long.parseLong(item.get("expiresAt").n()));
        } catch (NumberFormatException | NullPointerException e) {
            expiresAt = Instant.EPOCH;
        }
        return new ProfileHandler.LinkCode(text(item, "profileId"), text(item, "createdBy"), expiresAt);
    }
}
