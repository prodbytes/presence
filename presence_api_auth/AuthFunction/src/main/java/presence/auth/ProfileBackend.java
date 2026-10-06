package presence.auth;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.GetIdRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityResponse;
import software.amazon.awssdk.services.cognitoidentity.model.NotAuthorizedException;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;
import software.amazon.awssdk.services.iot.IotClient;
import software.amazon.awssdk.services.iot.model.AttachPolicyRequest;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;

import java.time.Instant;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

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
        var http = UrlConnectionHttpClient.create();
        var iotPolicy = System.getenv("IOT_POLICY_NAME");
        return new ProfileBackend(
                DynamoDbClient.builder().httpClient(http).build(),
                CognitoIdentityClient.builder().httpClient(http).build(),
                S3Client.builder().httpClient(http).build(),
                System.getenv("LINK_CODES_TABLE"),
                System.getenv("COGNITO_IDENTITY_POOL_ID"),
                System.getenv("DEVELOPER_PROVIDER"),
                System.getenv("USER_DATA_BUCKET"),
                iotPolicy == null || iotPolicy.isBlank() ? null : IotClient.builder().httpClient(http).build(),
                iotPolicy);
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
            return Optional.of(new ProfileHandler.LinkCode(text(old, "profileId"), text(old, "createdBy"),
                    Instant.ofEpochSecond(Long.parseLong(old.get("expiresAt").n()))));
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
        GetOpenIdTokenForDeveloperIdentityResponse result;
        try {
            // Once linked, the profile ID alone is the proof.
            result = openIdToken(identityId, Map.of(developerProvider, profileId));
        } catch (NotAuthorizedException e) {
            // Not linked yet: the identity was made by Google sign-in (GetId),
            // and Cognito links another login to it only beside one it has
            // ("Logins don't match").
            if (googleIdToken == null || googleIdToken.isBlank()) {
                throw e;
            }
            result = openIdToken(identityId, Map.of(developerProvider, profileId, GOOGLE, googleIdToken));
        }
        if (!identityId.equals(result.identityId())) {
            // Never hand out another folder's credentials.
            throw new IllegalStateException("Cognito answered for identity " + result.identityId()
                    + ", not " + identityId);
        }
        return result.token();
    }

    private GetOpenIdTokenForDeveloperIdentityResponse openIdToken(String identityId, Map<String, String> logins) {
        return cognito.getOpenIdTokenForDeveloperIdentity(GetOpenIdTokenForDeveloperIdentityRequest.builder()
                .identityPoolId(identityPoolId)
                .identityId(identityId)
                .logins(logins)
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
                    + ProfileHandler.cause(e) + ": " + e);
        }
    }

    private static String text(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        return value == null || value.s() == null ? "" : value.s();
    }
}
