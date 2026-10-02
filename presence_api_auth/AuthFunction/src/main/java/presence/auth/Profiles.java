package presence.auth;

import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.time.Clock;
import java.time.Instant;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.function.Supplier;

/**
 * A profile is whose data it is: a stable ID that outlives the ways its
 * owner signs in. Each authenticated subject (a token's issuer and
 * {@code sub}) is linked to one profile; signing in finds it, or creates a
 * profile and links the subject, so the next sign-in finds the same one.
 * Data belongs to the profile, not the subject or the email, so more
 * subjects (another provider, a new email, a collaborator) can be linked to
 * it later without losing anything.
 */
public final class Profiles {

    /** A subject's key in the links table: {@code <iss>#<sub>}. */
    static String subject(String issuer, String sub) {
        return issuer + "#" + sub;
    }

    /** The profiles table and the subject links table. */
    interface Store {
        /** Creates the profile {@code id}, unless one has that ID: then false. */
        boolean create(String id, Instant now);

        /** The profile {@code subject} is linked to, or null. */
        String linked(String subject);

        /** Links {@code subject} to {@code profileId}, unless it's already linked: then false. */
        boolean link(String subject, String profileId, String email, Instant now);

        /** Records a sign-in to the profile, creating it if it doesn't exist. */
        void signedIn(String profileId, Instant now);
    }

    /** How many taken IDs a first sign-in tries before giving up. */
    static final int ATTEMPTS = 10;

    private final Store store;
    private final Clock clock;
    private final Supplier<String> ids;

    public Profiles(Store store, Clock clock, Supplier<String> ids) {
        this.store = store;
        this.clock = clock;
        this.ids = ids;
    }

    /** Profile IDs are {@link ProfileId}s. */
    public Profiles(Store store) {
        this(store, Clock.systemUTC(), ProfileId::generate);
    }

    /**
     * The profile of the subject {@code sub} from {@code issuer}: the one it's
     * linked to, or a new one it's linked to from now on. Null without both.
     */
    public String of(String issuer, String sub, String email) {
        if (issuer == null || issuer.isBlank() || sub == null || sub.isBlank()) {
            return null;
        }
        var subject = subject(issuer, sub);
        var now = clock.instant();
        var profile = store.linked(subject);
        if (profile != null) {
            // Also creates the profile if a link names one that doesn't exist.
            store.signedIn(profile, now);
            return profile;
        }
        var created = create(now);
        // Two first sign-ins at once: the first link wins, the other reads it
        // (leaving its new profile unused).
        return store.link(subject, created, email, now) ? created : store.linked(subject);
    }

    /** A new profile, with an ID no other profile has. */
    private String create(Instant now) {
        for (var attempt = 0; attempt < ATTEMPTS; attempt++) {
            var id = ids.get();
            if (store.create(id, now)) {
                return id;
            }
        }
        throw new IllegalStateException("no free profile ID after " + ATTEMPTS + " attempts");
    }

    /**
     * Profiles in {@code profilesTable} ({@code id}, a {@link ProfileId}, {@code createdAt},
     * {@code lastSignInAt}) and links in {@code subjectsTable}
     * ({@code subject}, {@code profileId}, {@code email}, {@code linkedAt}).
     * Times are epoch milliseconds.
     */
    static Store dynamoStore(DynamoDbClient dynamo, String profilesTable, String subjectsTable) {
        return new Store() {
            @Override
            public boolean create(String id, Instant now) {
                var time = AttributeValue.fromN(Long.toString(now.toEpochMilli()));
                try {
                    dynamo.putItem(PutItemRequest.builder()
                            .tableName(profilesTable)
                            .item(Map.of("id", AttributeValue.fromS(id), "createdAt", time, "lastSignInAt", time))
                            .conditionExpression("attribute_not_exists(id)")
                            .build());
                    return true;
                } catch (ConditionalCheckFailedException e) {
                    return false;
                }
            }

            @Override
            public String linked(String subject) {
                var item = dynamo.getItem(GetItemRequest.builder()
                        .tableName(subjectsTable)
                        .key(Map.of("subject", AttributeValue.fromS(subject)))
                        .consistentRead(true)
                        .build()).item();
                var id = item == null ? null : item.get("profileId");
                return id == null || id.s() == null || id.s().isBlank() ? null : id.s();
            }

            @Override
            public boolean link(String subject, String profileId, String email, Instant now) {
                var item = new HashMap<String, AttributeValue>();
                item.put("subject", AttributeValue.fromS(subject));
                item.put("profileId", AttributeValue.fromS(profileId));
                item.put("linkedAt", AttributeValue.fromN(Long.toString(now.toEpochMilli())));
                if (email != null && !email.isBlank()) {
                    item.put("email", AttributeValue.fromS(email.strip().toLowerCase(Locale.ROOT)));
                }
                try {
                    dynamo.putItem(PutItemRequest.builder()
                            .tableName(subjectsTable)
                            .item(item)
                            .conditionExpression("attribute_not_exists(subject)")
                            .build());
                    return true;
                } catch (ConditionalCheckFailedException e) {
                    return false;
                }
            }

            @Override
            public void signedIn(String profileId, Instant now) {
                dynamo.updateItem(UpdateItemRequest.builder()
                        .tableName(profilesTable)
                        .key(Map.of("id", AttributeValue.fromS(profileId)))
                        .updateExpression("SET createdAt = if_not_exists(createdAt, :now), lastSignInAt = :now")
                        .expressionAttributeValues(Map.of(
                                ":now", AttributeValue.fromN(Long.toString(now.toEpochMilli()))))
                        .build());
            }
        };
    }
}
