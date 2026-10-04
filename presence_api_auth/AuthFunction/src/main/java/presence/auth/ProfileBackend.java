package presence.auth;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.GetIdRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityRequest;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;

import java.time.Instant;
import java.util.Map;
import java.util.Optional;

/**
 * {@link ProfileHandler.Backend} in AWS: the link-codes table (DynamoDB),
 * the identity pool (Cognito, its developer provider) and the user-data
 * bucket (S3, only to see whether a folder is empty). Profiles and their
 * subjects are {@link Profiles}'.
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

    ProfileBackend(DynamoDbClient dynamo, CognitoIdentityClient cognito, S3Client s3,
                   String codesTable, String identityPoolId, String developerProvider, String bucket) {
        this.dynamo = dynamo;
        this.cognito = cognito;
        this.s3 = s3;
        this.codesTable = codesTable;
        this.identityPoolId = identityPoolId;
        this.developerProvider = developerProvider;
        this.bucket = bucket;
    }

    /** Whether the function has an identity pool and a bucket (template parameters, empty locally). */
    static boolean configured() {
        return Settings.fromEnvironment().aws();
    }

    static ProfileBackend fromEnvironment() {
        var http = UrlConnectionHttpClient.create();
        return new ProfileBackend(
                DynamoDbClient.builder().httpClient(http).build(),
                CognitoIdentityClient.builder().httpClient(http).build(),
                S3Client.builder().httpClient(http).build(),
                System.getenv("LINK_CODES_TABLE"),
                System.getenv("COGNITO_IDENTITY_POOL_ID"),
                System.getenv("DEVELOPER_PROVIDER"),
                System.getenv("USER_DATA_BUCKET"));
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
    public String openIdToken(String identityId, String profileId) {
        var result = cognito.getOpenIdTokenForDeveloperIdentity(GetOpenIdTokenForDeveloperIdentityRequest.builder()
                .identityPoolId(identityPoolId)
                .identityId(identityId)
                .logins(Map.of(developerProvider, profileId))
                .build());
        if (!identityId.equals(result.identityId())) {
            // Never hand out another folder's credentials.
            throw new IllegalStateException("Cognito answered for identity " + result.identityId()
                    + ", not " + identityId);
        }
        return result.token();
    }

    @Override
    public boolean folderEmpty(String identityId) {
        return s3.listObjectsV2(ListObjectsV2Request.builder()
                .bucket(bucket)
                .prefix(identityId + "/")
                .maxKeys(1)
                .build()).keyCount() == 0;
    }

    private static String text(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        return value == null || value.s() == null ? "" : value.s();
    }
}
