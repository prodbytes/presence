package presence.auth;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.GetIdRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityRequest;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * {@link Profiles.Backend} in AWS: the accounts and link-codes tables
 * (DynamoDB), the identity pool (Cognito, its developer provider) and the
 * user-data bucket (S3, only to see whether a folder is empty).
 */
final class ProfileBackend implements Profiles.Backend {

    /** The provider the app's Google ID tokens sign in to directly (the pool's SupportedLoginProviders). */
    static final String GOOGLE = "accounts.google.com";

    /** The accounts table's index by profile. */
    static final String PROFILE_INDEX = "profile";

    private final DynamoDbClient dynamo;
    private final CognitoIdentityClient cognito;
    private final S3Client s3;
    private final String accountsTable;
    private final String codesTable;
    private final String identityPoolId;
    private final String developerProvider;
    private final String bucket;

    ProfileBackend(DynamoDbClient dynamo, CognitoIdentityClient cognito, S3Client s3, String accountsTable,
                   String codesTable, String identityPoolId, String developerProvider, String bucket) {
        this.dynamo = dynamo;
        this.cognito = cognito;
        this.s3 = s3;
        this.accountsTable = accountsTable;
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
                System.getenv("ACCOUNTS_TABLE"),
                System.getenv("LINK_CODES_TABLE"),
                System.getenv("COGNITO_IDENTITY_POOL_ID"),
                System.getenv("DEVELOPER_PROVIDER"),
                System.getenv("USER_DATA_BUCKET"));
    }

    @Override
    public Optional<Profiles.Account> account(String sub) {
        var item = dynamo.getItem(GetItemRequest.builder()
                .tableName(accountsTable)
                .key(Map.of("sub", AttributeValue.fromS(sub)))
                .consistentRead(true)
                .build()).item();
        return item == null || item.isEmpty() ? Optional.empty() : Optional.of(account(item));
    }

    @Override
    public boolean create(Profiles.Account account) {
        try {
            dynamo.putItem(PutItemRequest.builder()
                    .tableName(accountsTable)
                    .item(item(account))
                    .conditionExpression("attribute_not_exists(#sub)")
                    .expressionAttributeNames(Map.of("#sub", "sub"))
                    .build());
            return true;
        } catch (ConditionalCheckFailedException e) {
            return false;
        }
    }

    @Override
    public void put(Profiles.Account account) {
        dynamo.putItem(PutItemRequest.builder().tableName(accountsTable).item(item(account)).build());
    }

    @Override
    public void delete(String sub) {
        dynamo.deleteItem(DeleteItemRequest.builder()
                .tableName(accountsTable)
                .key(Map.of("sub", AttributeValue.fromS(sub)))
                .build());
    }

    @Override
    public List<Profiles.Account> members(String profileId) {
        var result = new ArrayList<Profiles.Account>();
        var query = QueryRequest.builder()
                .tableName(accountsTable)
                .indexName(PROFILE_INDEX)
                .keyConditionExpression("profileId = :p")
                .expressionAttributeValues(Map.of(":p", AttributeValue.fromS(profileId)))
                .build();
        for (var page : dynamo.queryPaginator(query)) {
            page.items().stream().map(ProfileBackend::account).forEach(result::add);
        }
        return result;
    }

    @Override
    public void saveCode(String hash, Profiles.LinkCode code) {
        dynamo.putItem(PutItemRequest.builder()
                .tableName(codesTable)
                .item(Map.of(
                        "code", AttributeValue.fromS(hash),
                        "profileId", AttributeValue.fromS(code.profileId()),
                        "identityId", AttributeValue.fromS(code.identityId()),
                        "ownerEmail", AttributeValue.fromS(code.ownerEmail()),
                        "createdBy", AttributeValue.fromS(code.createdBy()),
                        // Epoch seconds: the table's TTL attribute.
                        "expiresAt", AttributeValue.fromN(Long.toString(code.expiresAt().getEpochSecond()))))
                .build());
    }

    @Override
    public Optional<Profiles.LinkCode> takeCode(String hash, Instant now) {
        try {
            // One use: deleted as it's read. TTL deletion lags, hence the check.
            var old = dynamo.deleteItem(DeleteItemRequest.builder()
                    .tableName(codesTable)
                    .key(Map.of("code", AttributeValue.fromS(hash)))
                    .conditionExpression("expiresAt > :now")
                    .expressionAttributeValues(Map.of(":now", AttributeValue.fromN(Long.toString(now.getEpochSecond()))))
                    .returnValues(ReturnValue.ALL_OLD)
                    .build()).attributes();
            return Optional.of(new Profiles.LinkCode(text(old, "profileId"), text(old, "identityId"),
                    text(old, "ownerEmail"), text(old, "createdBy"),
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

    private static Map<String, AttributeValue> item(Profiles.Account a) {
        var item = new HashMap<String, AttributeValue>();
        item.put("sub", AttributeValue.fromS(a.sub()));
        item.put("email", AttributeValue.fromS(a.email()));
        item.put("profileId", AttributeValue.fromS(a.profileId()));
        item.put("identityId", AttributeValue.fromS(a.identityId()));
        item.put("ownerEmail", AttributeValue.fromS(a.ownerEmail()));
        item.put("owner", AttributeValue.fromBool(a.owner()));
        item.put("linkedAt", AttributeValue.fromN(Long.toString(a.linkedAt().toEpochMilli())));
        return item;
    }

    private static Profiles.Account account(Map<String, AttributeValue> item) {
        var owner = item.get("owner");
        var linkedAt = item.get("linkedAt");
        return new Profiles.Account(text(item, "sub"), text(item, "email"), text(item, "profileId"),
                text(item, "identityId"), text(item, "ownerEmail"),
                owner != null && Boolean.TRUE.equals(owner.bool()),
                linkedAt == null ? Instant.EPOCH : Instant.ofEpochMilli(Long.parseLong(linkedAt.n())));
    }

    private static String text(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        return value == null || value.s() == null ? "" : value.s();
    }
}
