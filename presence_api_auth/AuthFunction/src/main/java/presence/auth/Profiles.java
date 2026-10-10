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
import java.util.Objects;
import java.util.function.Supplier;

import static presence.auth.Attrs.text;

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
 *
 * <p>The owner's email (and Workspace domain, {@code hd}) is kept only from
 * a token whose {@code email_verified} is true, since linked subjects share
 * the owner's membership ({@link Roles#of(Caller, Profile)}).
 *
 * <p>Squatting: the app's profile ID ({@code ?profile=<id>}) is a name, not
 * a secret, and the first subject to sign in with a free one claims it. One
 * who learns another install's ID before that install's first sign-in can
 * take it; the install then gets a fresh profile at its sign-in, and the
 * squatter gets an empty profile (data is the profile's once signed in, and
 * uploads need a profile's credentials), so it's a nuisance, not a leak.
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
     * @param ownerEmail   the owner's verified email (null if none), whose membership every linked subject shares
     * @param ownerHd      the owner's Google Workspace domain ({@code hd}) when that email was seen; null if none
     */
    record Profile(String id, String identityId, String ownerSubject, String ownerEmail, String ownerHd) {

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
        boolean create(String id, String ownerSubject, String ownerEmail, String ownerHd, Instant now);

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

        /** The owner's new verified email and its {@code hd}; null removes either. */
        void owner(String profileId, String email, String hd);

        /** Sets the profile's identity unless it has one; the profile after. */
        Profile identity(String profileId, String identityId);

        /**
         * Adds {@code deviceId} at the end of the profile's devices, unless
         * it's there already or the profile has {@code max} of them; the
         * profile's devices after, in the order they were added.
         */
        List<String> addDevice(String profileId, String deviceId, int max);

        /** Takes {@code deviceId} out of the profile's devices; the devices left. */
        List<String> removeDevice(String profileId, String deviceId);

        /** The profile's devices, in the order they were added. */
        List<String> devices(String profileId);
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

    /** The ID of {@link #profile}'s profile, for a verified {@code email} without {@code hd}; or null. */
    public String of(String issuer, String sub, String email) {
        return of(issuer, sub, email, null);
    }

    /** The ID of {@link #profile}'s profile, for a verified {@code email} without {@code hd}; or null. */
    public String of(String issuer, String sub, String email, String requested) {
        var profile = profile(caller(issuer, sub, email), requested);
        return profile == null ? null : profile.id();
    }

    /** {@link #profile(Caller, String)}, without an ID from the app, for a verified {@code email}. */
    public Profile profile(String issuer, String sub, String email) {
        return profile(caller(issuer, sub, email), null);
    }

    private static Caller caller(String issuer, String sub, String email) {
        var claims = new HashMap<String, String>();
        claims.put("email_verified", "true");
        if (issuer != null) {
            claims.put("iss", issuer);
        }
        if (sub != null) {
            claims.put("sub", sub);
        }
        if (email != null) {
            claims.put("email", email);
        }
        return Caller.of(claims);
    }

    /**
     * The profile of the caller's subject (its {@code iss} and {@code sub}):
     * the one it's linked to, or a new one it owns and is linked to from now
     * on. The new one gets the ID {@code requested}, the app's own profile
     * ID, if it's a {@link ProfileId#valid valid} one no profile has;
     * otherwise a fresh one. Null without a subject. Only a verified email
     * is stored (as the owner's, or the link's); an owner's verified new
     * email replaces the old, and an unverified one never does.
     */
    public Profile profile(Caller caller, String requested) {
        if (!caller.hasSubject()) {
            return null;
        }
        var subject = caller.subject();
        var email = caller.verifiedEmail();
        var hd = email == null ? null : caller.hd();
        var now = clock.instant();
        var linked = store.linked(subject);
        if (linked != null) {
            // Also creates the profile if a link names one that doesn't exist.
            var profile = store.signedIn(linked, now);
            if (!subject.equals(profile.ownerSubject())) {
                return profile;
            }
            if (email != null && (!email.equals(profile.ownerEmail()) || !Objects.equals(hd, profile.ownerHd()))) {
                store.owner(linked, email, hd);
                return new Profile(profile.id(), profile.identityId(), subject, email, hd);
            }
            if (email == null && profile.ownerEmail() != null && caller.email() != null
                    && caller.email().strip().equalsIgnoreCase(profile.ownerEmail())) {
                // Kept before only verified emails were: the token says it isn't.
                store.owner(linked, null, null);
                return new Profile(profile.id(), profile.identityId(), subject, null, null);
            }
            return profile;
        }
        var created = create(subject, email, hd, requested, now);
        // Two first sign-ins at once: the first link wins, the other reads it
        // (leaving its new profile unused).
        if (store.link(subject, created, email, now)) {
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
    private String create(String subject, String email, String hd, String requested, Instant now) {
        if (ProfileId.valid(requested) && store.create(requested, subject, email, hd, now)) {
            return requested;
        }
        for (var attempt = 0; attempt < ATTEMPTS; attempt++) {
            var id = ids.get();
            if (store.create(id, subject, email, hd, now)) {
                return id;
            }
        }
        throw new IllegalStateException("no free profile ID after " + ATTEMPTS + " attempts");
    }

    /** From the function's environment (see template.yaml). */
    static Profiles fromEnvironment() {
        return new Profiles(dynamoStore(Aws.dynamo(),
                System.getenv("PROFILES_TABLE"), System.getenv("PROFILE_SUBJECTS_TABLE")));
    }

    /** The subjects table's index by profile. */
    static final String PROFILE_INDEX = "profile";

    /**
     * Profiles in {@code profilesTable} ({@code id}, a {@link ProfileId},
     * {@code createdAt}, {@code lastSignInAt}, {@code ownerSubject},
     * {@code ownerEmail}, {@code ownerHd}, {@code identityId}, {@code devices},
     * a list of device IDs in the order they were added) and links in
     * {@code subjectsTable} ({@code subject}, {@code profileId}, {@code email},
     * {@code linkedAt}; indexed by {@code profileId}). Times are epoch
     * milliseconds.
     */
    static Store dynamoStore(DynamoDbClient dynamo, String profilesTable, String subjectsTable) {
        return new Store() {
            @Override
            public boolean create(String id, String ownerSubject, String ownerEmail, String ownerHd, Instant now) {
                var time = AttributeValue.fromN(Long.toString(now.toEpochMilli()));
                var item = new HashMap<String, AttributeValue>();
                item.put("id", AttributeValue.fromS(id));
                item.put("createdAt", time);
                item.put("lastSignInAt", time);
                item.put("ownerSubject", AttributeValue.fromS(ownerSubject));
                if (ownerEmail != null) {
                    item.put("ownerEmail", AttributeValue.fromS(ownerEmail));
                }
                if (ownerHd != null) {
                    item.put("ownerHd", AttributeValue.fromS(ownerHd));
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
            public void owner(String profileId, String email, String hd) {
                var set = new ArrayList<String>();
                var remove = new ArrayList<String>();
                var values = new HashMap<String, AttributeValue>();
                if (email == null) {
                    remove.add("ownerEmail");
                } else {
                    set.add("ownerEmail = :email");
                    values.put(":email", AttributeValue.fromS(email));
                }
                if (hd == null) {
                    remove.add("ownerHd");
                } else {
                    set.add("ownerHd = :hd");
                    values.put(":hd", AttributeValue.fromS(hd));
                }
                var expression = (set.isEmpty() ? "" : "SET " + String.join(", ", set))
                        + (remove.isEmpty() ? "" : (set.isEmpty() ? "" : " ") + "REMOVE " + String.join(", ", remove));
                var update = UpdateItemRequest.builder()
                        .tableName(profilesTable)
                        .key(Map.of("id", AttributeValue.fromS(profileId)))
                        .updateExpression(expression);
                if (!values.isEmpty()) {
                    update.expressionAttributeValues(values);
                }
                dynamo.updateItem(update.build());
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

            @Override
            public List<String> addDevice(String profileId, String deviceId, int max) {
                try {
                    return devicesOf(dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(profilesTable)
                            .key(Map.of("id", AttributeValue.fromS(profileId)))
                            .updateExpression("SET devices = list_append(if_not_exists(devices, :none), :device)")
                            // Once each, and never more than max: two devices
                            // adding themselves at once both land, in order.
                            .conditionExpression("attribute_exists(id) AND (attribute_not_exists(devices)"
                                    + " OR (NOT contains(devices, :id) AND size(devices) < :max))")
                            .expressionAttributeValues(Map.of(
                                    ":none", AttributeValue.fromL(List.of()),
                                    ":device", AttributeValue.fromL(List.of(AttributeValue.fromS(deviceId))),
                                    ":id", AttributeValue.fromS(deviceId),
                                    ":max", AttributeValue.fromN(Integer.toString(max))))
                            .returnValues(ReturnValue.ALL_NEW)
                            .build()).attributes());
                } catch (ConditionalCheckFailedException e) {
                    return devices(profileId);
                }
            }

            @Override
            public List<String> removeDevice(String profileId, String deviceId) {
                // A list's element is removed by its index: the condition
                // checks it's still the device's, and a change meanwhile
                // reads the list again.
                for (var attempt = 0; attempt < ATTEMPTS; attempt++) {
                    var devices = devices(profileId);
                    var index = devices.indexOf(deviceId);
                    if (index < 0) {
                        return devices;
                    }
                    try {
                        return devicesOf(dynamo.updateItem(UpdateItemRequest.builder()
                                .tableName(profilesTable)
                                .key(Map.of("id", AttributeValue.fromS(profileId)))
                                .updateExpression("REMOVE devices[" + index + "]")
                                .conditionExpression("devices[" + index + "] = :id")
                                .expressionAttributeValues(Map.of(":id", AttributeValue.fromS(deviceId)))
                                .returnValues(ReturnValue.ALL_NEW)
                                .build()).attributes());
                    } catch (ConditionalCheckFailedException e) {
                        // Changed meanwhile: again.
                    }
                }
                throw new IllegalStateException("the devices kept changing");
            }

            @Override
            public List<String> devices(String profileId) {
                var item = dynamo.getItem(GetItemRequest.builder()
                        .tableName(profilesTable)
                        .key(Map.of("id", AttributeValue.fromS(profileId)))
                        .consistentRead(true)
                        .build()).item();
                return devicesOf(item);
            }
        };
    }

    /** The {@code devices} list of a profile's item, in order; empty without one. */
    private static List<String> devicesOf(Map<String, AttributeValue> item) {
        var list = item == null ? null : item.get("devices");
        if (list == null || !list.hasL()) {
            return List.of();
        }
        return list.l().stream().map(AttributeValue::s).filter(Objects::nonNull).toList();
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
                nullIfEmpty(text(item, "ownerEmail")), nullIfEmpty(text(item, "ownerHd")));
    }

    private static String nullIfEmpty(String value) {
        return value.isEmpty() ? null : value;
    }
}
