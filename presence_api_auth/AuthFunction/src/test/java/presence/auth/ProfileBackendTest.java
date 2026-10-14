package presence.auth;

import org.junit.jupiter.api.Test;
import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.DeleteIdentitiesRequest;
import software.amazon.awssdk.services.cognitoidentity.model.DeleteIdentitiesResponse;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityResponse;
import software.amazon.awssdk.services.cognitoidentity.model.NotAuthorizedException;
import software.amazon.awssdk.services.cognitoidentity.model.UnprocessedIdentityId;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemResponse;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.QueryResponse;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.dynamodb.model.ScanResponse;
import software.amazon.awssdk.services.iot.IotClient;
import software.amazon.awssdk.services.iot.model.AttachPolicyRequest;
import software.amazon.awssdk.services.iot.model.AttachPolicyResponse;
import software.amazon.awssdk.services.iot.model.DetachPolicyRequest;
import software.amazon.awssdk.services.iot.model.DetachPolicyResponse;
import software.amazon.awssdk.services.iot.model.IotException;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.DeleteObjectsRequest;
import software.amazon.awssdk.services.s3.model.DeleteObjectsResponse;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Request;
import software.amazon.awssdk.services.s3.model.ListObjectsV2Response;
import software.amazon.awssdk.services.s3.model.S3Error;
import software.amazon.awssdk.services.s3.model.S3Object;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProfileBackendTest {

    private static final String DEV = "login.presence.profiles";

    /** As Cognito, for an identity Google sign-in made: a profile ID links to it only beside its Google login. */
    private static final class Cognito implements CognitoIdentityClient {
        final List<Map<String, String>> calls = new ArrayList<>();
        final List<Map<String, String>> tags = new ArrayList<>();
        String linkedProfile;

        @Override
        public GetOpenIdTokenForDeveloperIdentityResponse getOpenIdTokenForDeveloperIdentity(
                GetOpenIdTokenForDeveloperIdentityRequest request) {
            var logins = request.logins();
            calls.add(logins);
            tags.add(request.principalTags());
            var profile = logins.get(DEV);
            if (linkedProfile == null && "google-token".equals(logins.get(ProfileBackend.GOOGLE))) {
                linkedProfile = profile;
            }
            if (linkedProfile == null || !linkedProfile.equals(profile)) {
                throw NotAuthorizedException.builder().message("Logins don't match.").build();
            }
            return GetOpenIdTokenForDeveloperIdentityResponse.builder()
                    .identityId(request.identityId()).token("token").build();
        }

        final List<String> deleted = new ArrayList<>();
        /** When set, DeleteIdentities answers it as the identity's error code. */
        String unprocessed;

        @Override
        public DeleteIdentitiesResponse deleteIdentities(DeleteIdentitiesRequest request) {
            if (unprocessed != null) {
                return DeleteIdentitiesResponse.builder().unprocessedIdentityIds(UnprocessedIdentityId.builder()
                        .identityId(request.identityIdsToDelete().getFirst()).errorCode(unprocessed).build()).build();
            }
            deleted.addAll(request.identityIdsToDelete());
            return DeleteIdentitiesResponse.builder().build();
        }

        @Override
        public String serviceName() {
            return "cognito-identity";
        }

        @Override
        public void close() {
        }
    }

    private final Cognito cognito = new Cognito();
    private final ProfileBackend backend = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket");

    @Test
    void theFirstTokenLinksTheProfileWithTheGoogleLogin() {
        assertEquals("token", backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token"));
        assertEquals(List.of(
                Map.of(DEV, "savvy_plaice"),
                Map.of(DEV, "savvy_plaice", ProfileBackend.GOOGLE, "google-token")), cognito.calls);

        // Linked: the profile ID alone from now on, from any linked account.
        cognito.calls.clear();
        assertEquals("token", backend.openIdToken("us-east-1:id", "savvy_plaice", "member-token"));
        assertEquals(List.of(Map.of(DEV, "savvy_plaice")), cognito.calls);
    }

    @Test
    void administratorsTokensAlsoCarryTheAdminTag() {
        backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token", ProfileHandler.FREE, true);
        assertEquals(List.of(Map.of("tier", "free", "admin", "true"), Map.of("tier", "free", "admin", "true")),
                cognito.tags);
        cognito.tags.clear();
        // Linked now: one try, without the admin tag for a member.
        backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token", ProfileHandler.FREE, false);
        assertEquals(List.of(Map.of("tier", "free")), cognito.tags);
    }

    @Test
    void tokensCarryTheTierAsAPrincipalTag() {
        backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token", ProfileHandler.PREMIUM);
        // Both tries (unlinked, then with the Google login) are tagged.
        assertEquals(List.of(Map.of("tier", "premium"), Map.of("tier", "premium")), cognito.tags);
        cognito.tags.clear();
        // Without a tier (a link code's token): free, never premium.
        backend.openIdToken("us-east-1:id", "savvy_plaice", null);
        assertEquals(List.of(Map.of("tier", "free")), cognito.tags);
    }

    /** AWS IoT's control plane: records AttachPolicy calls, or fails them. */
    private static final class Iot implements IotClient {
        final List<String> attached = new ArrayList<>();
        RuntimeException fails;

        @Override
        public AttachPolicyResponse attachPolicy(AttachPolicyRequest request) {
            if (fails != null) {
                throw fails;
            }
            attached.add(request.policyName() + " -> " + request.target());
            return AttachPolicyResponse.builder().build();
        }

        final List<String> detached = new ArrayList<>();

        @Override
        public DetachPolicyResponse detachPolicy(DetachPolicyRequest request) {
            if (fails != null) {
                throw fails;
            }
            detached.add(request.policyName() + " -> " + request.target());
            return DetachPolicyResponse.builder().build();
        }

        @Override
        public String serviceName() {
            return "iot";
        }

        @Override
        public void close() {
        }
    }

    @Test
    void liveSyncAttachesThePolicyToTheIdentityOncePerInstance() {
        var iot = new Iot();
        var live = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "presence-live-sync");
        live.allowLiveSync("us-east-1:id");
        live.allowLiveSync("us-east-1:id");
        live.allowLiveSync("us-east-1:other");
        assertEquals(List.of("presence-live-sync -> us-east-1:id", "presence-live-sync -> us-east-1:other"),
                iot.attached);
    }

    @Test
    void aFailedAttachDoesntFailCredentialsAndIsTriedAgain() {
        var iot = new Iot();
        var live = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "presence-live-sync");
        iot.fails = IotException.builder().message("throttled").statusCode(429).build();
        live.allowLiveSync("us-east-1:id");
        iot.fails = null;
        live.allowLiveSync("us-east-1:id");
        assertEquals(List.of("presence-live-sync -> us-east-1:id"), iot.attached);
    }

    @Test
    void withoutAPolicyNothingIsAttached() {
        var iot = new Iot();
        new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "").allowLiveSync("us-east-1:id");
        backend.allowLiveSync("us-east-1:id");
        assertEquals(List.of(), iot.attached);
    }

    private static final String IDENTITY = "us-east-1:0a1b2c3d-0000-4000-8000-00000000abcd";

    /** S3: a bucket's keys, listed in order, 1000 a page; deleted with DeleteObjects. */
    private static final class S3 implements S3Client {
        final java.util.TreeSet<String> keys = new java.util.TreeSet<>();
        final List<Integer> batches = new ArrayList<>();
        /** When set, DeleteObjects reports this error code for every key. */
        String refuses;

        @Override
        public ListObjectsV2Response listObjectsV2(ListObjectsV2Request request) {
            var page = keys.stream().filter(k -> k.startsWith(request.prefix())).limit(request.maxKeys())
                    .map(k -> S3Object.builder().key(k).build()).toList();
            return ListObjectsV2Response.builder().contents(page).keyCount(page.size()).build();
        }

        @Override
        public DeleteObjectsResponse deleteObjects(DeleteObjectsRequest request) {
            var objects = request.delete().objects();
            if (refuses != null) {
                return DeleteObjectsResponse.builder().errors(objects.stream()
                        .map(o -> S3Error.builder().key(o.key()).code(refuses).build()).toList()).build();
            }
            batches.add(objects.size());
            objects.forEach(o -> keys.remove(o.key()));
            return DeleteObjectsResponse.builder().build();
        }

        @Override
        public String serviceName() {
            return "s3";
        }

        @Override
        public void close() {
        }
    }

    @Test
    void deletingAFolderDeletesEveryObjectInItAPageAtATime() {
        var s3 = new S3();
        for (var i = 0; i < 2500; i++) {
            s3.keys.add(IDENTITY + "/events/" + i + ".json");
        }
        s3.keys.add("us-east-1:0a1b2c3d-0000-4000-8000-00000000ffff/events/1.json");
        s3.keys.add(IDENTITY + "-not-it/x.json");
        var folders = new ProfileBackend(null, cognito, s3, "codes", "pool", DEV, "bucket");

        var result = folders.deleteFolder(IDENTITY, java.time.Instant.MAX);

        assertEquals(new ProfileHandler.FolderDeletion(2500, true), result);
        assertEquals(List.of(1000, 1000, 500), s3.batches);
        // Other folders, even one whose name starts the same, stay.
        assertEquals(2, s3.keys.size());
        // Again: nothing left, done.
        assertEquals(new ProfileHandler.FolderDeletion(0, true), folders.deleteFolder(IDENTITY, java.time.Instant.MAX));
    }

    @Test
    void aFolderDeletionStopsWhenItsTimeIsUp() {
        var s3 = new S3();
        for (var i = 0; i < 2500; i++) {
            s3.keys.add(IDENTITY + "/media/" + i + ".jpg");
        }
        var folders = new ProfileBackend(null, cognito, s3, "codes", "pool", DEV, "bucket");

        var result = folders.deleteFolder(IDENTITY, java.time.Instant.EPOCH);

        assertEquals(new ProfileHandler.FolderDeletion(1000, false), result);
        assertEquals(1500, s3.keys.size());
    }

    @Test
    void onlyAnIdentitysFolderIsDeleted() {
        var s3 = new S3();
        s3.keys.add("a.json");
        var folders = new ProfileBackend(null, cognito, s3, "codes", "pool", DEV, "bucket");
        for (var prefix : new String[] {null, "", "us-east-1", "us-east-1:", "*", "../x", IDENTITY + "/x",
                "us-east-1:work"}) {
            assertThrows(IllegalArgumentException.class, () -> folders.deleteFolder(prefix, java.time.Instant.MAX),
                    String.valueOf(prefix));
        }
        assertEquals(1, s3.keys.size());
    }

    @Test
    void aRefusedDeletionFails() {
        var s3 = new S3();
        s3.keys.add(IDENTITY + "/a.json");
        s3.refuses = "AccessDenied";
        var folders = new ProfileBackend(null, cognito, s3, "codes", "pool", DEV, "bucket");
        var e = assertThrows(IllegalStateException.class, () -> folders.deleteFolder(IDENTITY, java.time.Instant.MAX));
        assertEquals("S3 didn't delete 1 of 1 objects: AccessDenied", e.getMessage());
    }

    @Test
    void deletingTheIdentityDetachesLiveSyncAndDeletesItFromThePool() {
        var iot = new Iot();
        var live = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "presence-live-sync");
        assertEquals(true, live.deleteIdentity(IDENTITY));
        assertEquals(List.of("presence-live-sync -> " + IDENTITY), iot.detached);
        assertEquals(List.of(IDENTITY), cognito.deleted);
    }

    @Test
    void aFailedIdentityDeletionIsReportedNotThrown() {
        var iot = new Iot();
        iot.fails = IotException.builder().message("not attached").statusCode(404).build();
        var live = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "presence-live-sync");
        cognito.unprocessed = "AccessDenied";
        assertEquals(false, live.deleteIdentity(IDENTITY));
        cognito.unprocessed = null;
        // A failed detach doesn't keep the identity.
        assertEquals(true, live.deleteIdentity(IDENTITY));
        assertEquals(List.of(IDENTITY), cognito.deleted);
    }

    /** DynamoDB: items per table; Query by the hash key, Scan with a filter, DeleteItem by key. */
    private static final class Dynamo implements DynamoDbClient {
        final Map<String, List<Map<String, AttributeValue>>> tables = new java.util.HashMap<>();
        final List<String> requests = new ArrayList<>();

        void put(String table, Map<String, String> item) {
            var values = new java.util.HashMap<String, AttributeValue>();
            item.forEach((k, v) -> values.put(k, k.equals("sentAt") ? AttributeValue.fromN(v) : AttributeValue.fromS(v)));
            tables.computeIfAbsent(table, t -> new ArrayList<>()).add(values);
        }

        @Override
        public QueryResponse query(QueryRequest request) {
            var names = request.expressionAttributeNames();
            var key = names.get(request.keyConditionExpression().split(" ")[0]);
            var value = request.expressionAttributeValues().values().iterator().next();
            requests.add("Query " + request.tableName() + " " + key + "=" + value.s());
            return QueryResponse.builder().items(tables.getOrDefault(request.tableName(), List.of()).stream()
                    .filter(i -> value.equals(i.get(key))).toList()).build();
        }

        @Override
        public ScanResponse scan(ScanRequest request) {
            var names = request.expressionAttributeNames();
            var filter = request.filterExpression();
            var value = request.expressionAttributeValues().get(":p").s();
            requests.add("Scan " + request.tableName() + " " + filter);
            var prefix = filter.startsWith("begins_with");
            var attribute = names.get(prefix ? filter.substring(12, filter.indexOf(',')) : filter.split(" ")[0]);
            return ScanResponse.builder().items(tables.getOrDefault(request.tableName(), List.of()).stream()
                    .filter(i -> i.get(attribute) != null && (prefix
                            ? i.get(attribute).s().startsWith(value) : i.get(attribute).s().equals(value)))
                    .toList()).build();
        }

        @Override
        public DeleteItemResponse deleteItem(DeleteItemRequest request) {
            tables.getOrDefault(request.tableName(), new ArrayList<>()).removeIf(i -> request.key().entrySet().stream()
                    .allMatch(e -> e.getValue().equals(i.get(e.getKey()))));
            return DeleteItemResponse.builder().build();
        }

        @Override
        public String serviceName() {
            return "dynamodb";
        }

        @Override
        public void close() {
        }
    }

    @Test
    void theProfilesRecordsAreFoundAndDeleted() {
        var dynamo = new Dynamo();
        dynamo.put("feedback", Map.of("conversation", IDENTITY, "sentAt", "1", "email", "julio@nu01.com"));
        dynamo.put("feedback", Map.of("conversation", IDENTITY, "sentAt", "2", "email", "Julio@Gmail.com"));
        dynamo.put("feedback", Map.of("conversation", IDENTITY, "sentAt", "3", "email", "admin@nu01.com"));
        dynamo.put("feedback", Map.of("conversation", "us-east-1:other", "sentAt", "1", "email", "julio@gmail.com"));
        dynamo.put("recognition", Map.of("profile", "savvy_plaice", "item", "model"));
        dynamo.put("recognition", Map.of("profile", "savvy_plaice", "item", "label#1"));
        dynamo.put("recognition", Map.of("profile", "other_plaice", "item", "model"));
        dynamo.put("keys", Map.of("device", "savvy_plaice/calm_quiet_otter", "hash", "h"));
        dynamo.put("keys", Map.of("device", "savvy_plaice_two/calm_quiet_otter", "hash", "h"));
        dynamo.put("codes", Map.of("code", "c1", "profileId", "savvy_plaice"));
        dynamo.put("codes", Map.of("code", "c2", "profileId", "savvy_plaice_two"));
        var records = new ProfileBackend(dynamo, cognito, null, "codes", "pool", DEV, "bucket");
        records.streamKeysTable = "keys";
        records.recognitionTable = "recognition";
        records.feedbackTable = "feedback";

        // A linked account's own messages only, whatever the case of its email.
        assertEquals(1, records.deleteFeedback(IDENTITY, "julio@gmail.com"));
        // The owner's: the whole conversation (an admin's replies too).
        assertEquals(2, records.deleteFeedback(IDENTITY, null));
        assertEquals(2, records.deleteRecognition("savvy_plaice"));
        // Only this profile's keys and codes, not a profile whose ID starts the same.
        assertEquals(1, records.deleteStreamKeys("savvy_plaice"));
        assertEquals(1, records.deleteLinkCodes("savvy_plaice"));

        assertEquals(1, dynamo.tables.get("feedback").size());
        assertEquals(1, dynamo.tables.get("recognition").size());
        assertEquals("savvy_plaice_two/calm_quiet_otter", dynamo.tables.get("keys").getFirst().get("device").s());
        assertEquals("c2", dynamo.tables.get("codes").getFirst().get("code").s());
    }

    @Test
    void withoutTheTablesNothingIsAsked() {
        var dynamo = new Dynamo();
        var records = new ProfileBackend(dynamo, cognito, null, "", "pool", DEV, "bucket");
        assertEquals(0, records.deleteFeedback(IDENTITY, null));
        assertEquals(0, records.deleteRecognition("savvy_plaice"));
        assertEquals(0, records.deleteStreamKeys("savvy_plaice"));
        assertEquals(0, records.deleteLinkCodes("savvy_plaice"));
        assertEquals(List.of(), dynamo.requests);
    }

    @Test
    void anotherGoogleAccountCantLinkIt() {
        assertThrows(NotAuthorizedException.class,
                () -> backend.openIdToken("us-east-1:id", "savvy_plaice", "member-token"));
        assertThrows(NotAuthorizedException.class,
                () -> backend.openIdToken("us-east-1:id", "savvy_plaice", null));
    }
}
