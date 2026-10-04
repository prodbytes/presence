package presence.auth;

import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.ReturnValue;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Supplier;

/**
 * A profile is whose data it is: a stable ID that outlives the ways its
 * owner signs in, with one folder in the user-data bucket (its Cognito
 * identity). The app makes a profile ID at its first start, owned by
 * nobody; the first sign-in with it claims that ID for the subject. Each
 * authenticated subject (a token's issuer and {@code sub}) is linked to one
 * profile; signing in finds it, or creates a profile the subject owns (with
 * the app's ID when it's free) and links it, so the next sign-in finds the
 * same one. Data
 * belongs to the profile, not the subject or the email, so more subjects
 * (another Google account, another provider, a new email) can be linked to
 * it with a link code ({@link ProfileHandler}) without losing anything.
 */
public final class Profiles {

    /** A subject's key in the links table: {@code <iss>#<sub>}. */
    static String subject(String issuer, String sub) {
        return issuer + "#" + sub;
    }

    /**
     * A profile, as stored.
     *
     * @param id           a {@link ProfileId}; Cognito's developer user identifier for it
     * @param identityId   its Cognito identity, its folder in the bucket; empty until its first credentials
     * @param ownerSubject the subject that made it, which can't be unlinked
     * @param ownerEmail   the owner's email, whose roles every linked subject shares
     */
    record Profile(String id, String identityId, String ownerSubject, String ownerEmail) {

        boolean hasIdentity() {
            return identityId != null && !identityId.isBlank();
        }
    }

    /** A subject linked to a profile, with its email as last seen. */
    record Member(String subject, String profileId, String email) {
    }

    /** The profiles table and the subject links table. */
    interface Store {
        /** Creates the profile {@code id}, owned by {@code ownerSubject}, unless one has that ID: then false. */
        boolean create(String id, String ownerSubject, String ownerEmail, Instant now);

        /** The profile {@code id}, or null. */
        Profile profile(String id);

        /** The profile {@code subject} is linked to, or null. */
        String linked(String subject);

        /** Links {@code subject} to {@code profileId}, unless it's already linked: then false. */
        boolean link(String subject, String profileId, String email, Instant now);

        /** Links {@code subject} to {@code profileId}, replacing any link it had. */
        void relink(String subject, String profileId, String email, Instant now);

        /** Removes {@code subject}'s link. */
        void unlink(String subject);

        /** Every subject linked to the profile. */
        List<Member> members(String profileId);

        /** Records a sign-in to the profile, creating it if it doesn't exist; the profile after. */
        Profile signedIn(String profileId, Instant now);

        /** The owner's new email. */
        void ownerEmail(String profileId, String email);

        /** Sets the profile's identity unless it has one; the profile after. */
        Profile identity(String profileId, String identityId);
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

    Store store() {
        return store;
    }

    Clock clock() {
        return clock;
    }

    /** The ID of {@link #profile}'s profile, or null. */
    public String of(String issuer, String sub, String email) {
        return of(issuer, sub, email, null);
    }

    /** The ID of {@link #profile}'s profile, or null. */
    public String of(String issuer, String sub, String email, String requested) {
        var profile = profile(issuer, sub, email, requested);
        return profile == null ? null : profile.id();
    }

    /** {@link #profile(String, String, String, String)}, without an ID from the app. */
    public Profile profile(String issuer, String sub, String email) {
        return profile(issuer, sub, email, null);
    }

    /**
     * The profile of the subject {@code sub} from {@code issuer}: the one it's
     * linked to, or a new one it owns and is linked to from now on. The new
     * one gets the ID {@code requested}, the app's own profile ID, if it's a
     * {@link ProfileId#valid valid} one no profile has; otherwise a fresh
     * one. Null without both.
     */
    public Profile profile(String issuer, String sub, String email, String requested) {
        if (issuer == null || issuer.isBlank() || sub == null || sub.isBlank()) {
            return null;
        }
        var subject = subject(issuer, sub);
        var normalized = email == null || email.isBlank() ? null : email.strip().toLowerCase(Locale.ROOT);
        var now = clock.instant();
        var linked = store.linked(subject);
        if (linked != null) {
            // Also creates the profile if a link names one that doesn't exist.
            var profile = store.signedIn(linked, now);
            if (subject.equals(profile.ownerSubject()) && normalized != null
                    && !normalized.equals(profile.ownerEmail())) {
                store.ownerEmail(linked, normalized);
                profile = new Profile(profile.id(), profile.identityId(), subject, normalized);
            }
            return profile;
        }
        var created = create(subject, normalized, requested, now);
        // Two first sign-ins at once: the first link wins, the other reads it
        // (leaving its new profile unused).
        if (store.link(subject, created, normalized, now)) {
            return store.profile(created);
        }
        return store.signedIn(store.linked(subject), now);
    }

    /** The profile {@code subject} is linked to, without creating one; null if none. */
    public Profile existing(String subject) {
        var linked = store.linked(subject);
        return linked == null ? null : store.profile(linked);
    }

    /**
     * A new profile, with an ID no other profile has: {@code requested} if
     * it's valid and free, so the app's profile becomes the subject's.
     */
    private String create(String subject, String email, String requested, Instant now) {
        if (ProfileId.valid(requested) && store.create(requested, subject, email, now)) {
            return requested;
        }
        for (var attempt = 0; attempt < ATTEMPTS; attempt++) {
            var id = ids.get();
            if (store.create(id, subject, email, now)) {
                return id;
            }
        }
        throw new IllegalStateException("no free profile ID after " + ATTEMPTS + " attempts");
    }

    /** The subjects table's index by profile. */
    static final String PROFILE_INDEX = "profile";

    /**
     * Profiles in {@code profilesTable} ({@code id}, a {@link ProfileId},
     * {@code createdAt}, {@code lastSignInAt}, {@code ownerSubject},
     * {@code ownerEmail}, {@code identityId}) and links in
     * {@code subjectsTable} ({@code subject}, {@code profileId}, {@code email},
     * {@code linkedAt}; indexed by {@code profileId}). Times are epoch
     * milliseconds.
     */
    static Store dynamoStore(DynamoDbClient dynamo, String profilesTable, String subjectsTable) {
        return new Store() {
            @Override
            public boolean create(String id, String ownerSubject, String ownerEmail, Instant now) {
                var time = AttributeValue.fromN(Long.toString(now.toEpochMilli()));
                var item = new HashMap<String, AttributeValue>();
                item.put("id", AttributeValue.fromS(id));
                item.put("createdAt", time);
                item.put("lastSignInAt", time);
                item.put("ownerSubject", AttributeValue.fromS(ownerSubject));
                if (ownerEmail != null) {
                    item.put("ownerEmail", AttributeValue.fromS(ownerEmail));
                }
                try {
                    dynamo.putItem(PutItemRequest.builder()
                            .tableName(profilesTable)
                            .item(item)
                            .conditionExpression("attribute_not_exists(id)")
                            .build());
                    return true;
                } catch (ConditionalCheckFailedException e) {
                    return false;
                }
            }

            @Override
            public Profile profile(String id) {
                var item = dynamo.getItem(GetItemRequest.builder()
                        .tableName(profilesTable)
                        .key(Map.of("id", AttributeValue.fromS(id)))
                        .consistentRead(true)
                        .build()).item();
                return item == null || item.isEmpty() ? null : profileOf(item);
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
                try {
                    dynamo.putItem(PutItemRequest.builder()
                            .tableName(subjectsTable)
                            .item(linkItem(subject, profileId, email, now))
                            .conditionExpression("attribute_not_exists(subject)")
                            .build());
                    return true;
                } catch (ConditionalCheckFailedException e) {
                    return false;
                }
            }

            @Override
            public void relink(String subject, String profileId, String email, Instant now) {
                dynamo.putItem(PutItemRequest.builder()
                        .tableName(subjectsTable)
                        .item(linkItem(subject, profileId, email, now))
                        .build());
            }

            @Override
            public void unlink(String subject) {
                dynamo.deleteItem(DeleteItemRequest.builder()
                        .tableName(subjectsTable)
                        .key(Map.of("subject", AttributeValue.fromS(subject)))
                        .build());
            }

            @Override
            public List<Member> members(String profileId) {
                var result = new ArrayList<Member>();
                var query = QueryRequest.builder()
                        .tableName(subjectsTable)
                        .indexName(PROFILE_INDEX)
                        .keyConditionExpression("profileId = :p")
                        .expressionAttributeValues(Map.of(":p", AttributeValue.fromS(profileId)))
                        .build();
                for (var page : dynamo.queryPaginator(query)) {
                    for (var item : page.items()) {
                        result.add(new Member(text(item, "subject"), text(item, "profileId"), text(item, "email")));
                    }
                }
                return result;
            }

            @Override
            public Profile signedIn(String profileId, Instant now) {
                return profileOf(dynamo.updateItem(UpdateItemRequest.builder()
                        .tableName(profilesTable)
                        .key(Map.of("id", AttributeValue.fromS(profileId)))
                        .updateExpression("SET createdAt = if_not_exists(createdAt, :now), lastSignInAt = :now")
                        .expressionAttributeValues(Map.of(
                                ":now", AttributeValue.fromN(Long.toString(now.toEpochMilli()))))
                        .returnValues(ReturnValue.ALL_NEW)
                        .build()).attributes());
            }

            @Override
            public void ownerEmail(String profileId, String email) {
                dynamo.updateItem(UpdateItemRequest.builder()
                        .tableName(profilesTable)
                        .key(Map.of("id", AttributeValue.fromS(profileId)))
                        .updateExpression("SET ownerEmail = :email")
                        .expressionAttributeValues(Map.of(":email", AttributeValue.fromS(email)))
                        .build());
            }

            @Override
            public Profile identity(String profileId, String identityId) {
                try {
                    return profileOf(dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(profilesTable)
                            .key(Map.of("id", AttributeValue.fromS(profileId)))
                            .updateExpression("SET identityId = :identity")
                            // Set once: a profile's folder never moves.
                            .conditionExpression("attribute_exists(id) AND attribute_not_exists(identityId)")
                            .expressionAttributeValues(Map.of(":identity", AttributeValue.fromS(identityId)))
                            .returnValues(ReturnValue.ALL_NEW)
                            .build()).attributes());
                } catch (ConditionalCheckFailedException e) {
                    return profile(profileId);
                }
            }
        };
    }

    private static Map<String, AttributeValue> linkItem(String subject, String profileId, String email, Instant now) {
        var item = new HashMap<String, AttributeValue>();
        item.put("subject", AttributeValue.fromS(subject));
        item.put("profileId", AttributeValue.fromS(profileId));
        item.put("linkedAt", AttributeValue.fromN(Long.toString(now.toEpochMilli())));
        if (email != null && !email.isBlank()) {
            item.put("email", AttributeValue.fromS(email.strip().toLowerCase(Locale.ROOT)));
        }
        return item;
    }

    private static Profile profileOf(Map<String, AttributeValue> item) {
        return new Profile(text(item, "id"), text(item, "identityId"), text(item, "ownerSubject"),
                text(item, "ownerEmail").isEmpty() ? null : text(item, "ownerEmail"));
    }

    private static String text(Map<String, AttributeValue> item, String name) {
        var value = item.get(name);
        return value == null || value.s() == null ? "" : value.s();
    }
}
