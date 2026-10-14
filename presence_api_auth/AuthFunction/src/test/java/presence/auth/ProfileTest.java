package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;
import software.amazon.awssdk.awscore.exception.AwsErrorDetails;
import software.amazon.awssdk.services.cognitoidentity.model.CognitoIdentityException;

import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ProfileTest {

    private static final Instant NOW = Instant.parse("2026-10-04T12:00:00Z");

    private static final String GOOGLE = "https://accounts.google.com";

    /** The profiles and subjects tables, link codes, and what Cognito and S3 hold. */
    private final MemoryProfiles store = new MemoryProfiles();
    private final Map<String, ProfileHandler.LinkCode> codes = new HashMap<>();
    /** "tok-<owner sub>" -> the identity Cognito makes for that owner's profile (newIdentity). */
    private final Map<String, String> googleIdentities = new HashMap<>();
    /** Identity -> the developer identifier (profile) linked to it. */
    private final Map<String, String> linked = new HashMap<>();
    private final Set<String> foldersWithData = new HashSet<>();
    private final List<String> tokensIssued = new ArrayList<>();
    /** The tier each credentials token was tagged with, in order. */
    private final List<String> tiers = new ArrayList<>();
    /** Whether each token issued was tagged admin. */
    private final List<Boolean> admins = new ArrayList<>();
    /** Identities the live-sync IoT policy was attached to, in order. */
    private final List<String> liveSyncAllowed = new ArrayList<>();
    private Clock clock = Clock.fixed(NOW, ZoneOffset.UTC);
    private int ids;
    /** When set, Cognito fails every token request with it. */
    private RuntimeException cognitoFails;

    private final ProfileHandler.Backend backend = new ProfileHandler.Backend() {
        @Override
        public void saveCode(String hash, ProfileHandler.LinkCode code) {
            codes.put(hash, code);
        }

        @Override
        public Optional<ProfileHandler.LinkCode> peekCode(String hash, Instant now) {
            var code = codes.get(hash);
            return code == null || !code.expiresAt().isAfter(now) ? Optional.empty() : Optional.of(code);
        }

        @Override
        public Optional<ProfileHandler.LinkCode> takeCode(String hash, Instant now) {
            var code = codes.remove(hash);
            return code == null || !code.expiresAt().isAfter(now) ? Optional.empty() : Optional.of(code);
        }

        @Override
        public String newIdentity(String profileId) {
            if (cognitoFails != null) {
                throw cognitoFails;
            }
            // The identity made for the profile: the one a test named for its
            // owner ("tok-<sub>"), or a new one. Made linked to the profile.
            var owner = store.profile(profileId).ownerSubject();
            var identity = googleIdentities.computeIfAbsent("tok-" + owner.substring(owner.indexOf('#') + 1),
                    t -> "us-east-1:new-" + googleIdentities.size());
            assertNull(linked.putIfAbsent(identity, profileId) == null ? null : linked.get(identity).equals(profileId)
                    ? null : "identity " + identity + " relinked");
            return identity;
        }

        @Override
        public String openIdToken(String identityId, String profileId) {
            if (cognitoFails != null) {
                throw cognitoFails;
            }
            // As Cognito: a developer identifier belongs to one identity.
            linked.putIfAbsent(identityId, profileId);
            assertEquals(profileId, linked.get(identityId), "identity " + identityId + " relinked");
            tokensIssued.add(identityId + "|" + profileId);
            return "token-for-" + identityId;
        }

        @Override
        public String openIdToken(String identityId, String profileId, String tier) {
            var token = openIdToken(identityId, profileId);
            tiers.add(tier);
            return token;
        }

        @Override
        public String openIdToken(String identityId, String profileId, String tier, boolean admin) {
            admins.add(admin);
            return openIdToken(identityId, profileId, tier);
        }

        @Override
        public boolean folderEmpty(String identityId) {
            return !foldersWithData.contains(identityId);
        }

        @Override
        public void allowLiveSync(String identityId) {
            liveSyncAllowed.add(identityId);
        }

        @Override
        public void saveStreamKey(String profileId, String deviceId, ProfileHandler.StreamKey key) {
            streamKeys.put(profileId + "/" + deviceId, key);
        }

        @Override
        public Optional<ProfileHandler.StreamKey> streamKey(String profileId, String deviceId) {
            return Optional.ofNullable(streamKeys.get(profileId + "/" + deviceId));
        }

        @Override
        public void deleteStreamKey(String profileId, String deviceId) {
            streamKeys.remove(profileId + "/" + deviceId);
        }
    };

    /** The stream keys table: "<profile>/<device>" -> the key's record. */
    private final Map<String, ProfileHandler.StreamKey> streamKeys = new HashMap<>();

    /** The streamer's call: no Google token, the stream key as the bearer. */
    private static APIGatewayV2HTTPEvent streamerCall(String key, String body) {
        var event = new APIGatewayV2HTTPEvent();
        event.setRequestContext(new APIGatewayV2HTTPEvent.RequestContext());
        event.setRouteKey(ProfileHandler.STREAM_CREDENTIALS);
        event.setHeaders(key == null ? Map.of() : Map.of("authorization", "Bearer " + key));
        event.setBody(body);
        return event;
    }

    /** A member makes a stream key for {@code device} of their profile; the key. */
    private String streamKeyFor(String sub, String email, String device) {
        var response = profiles.handleRequest(call("POST /api/auth/profile/stream-key", sub, email, device), null);
        assertEquals(200, response.getStatusCode(), response.getBody());
        var m = java.util.regex.Pattern.compile("\\\"key\\\":\\\"(psk_[A-Za-z0-9_-]{43})\\\"").matcher(response.getBody());
        assertTrue(m.find(), response.getBody());
        return m.group(1);
    }

    @Test
    void aStreamKeyGetsItsDeviceThePremiumProfilesCredentialsWithoutGoogle() {
        rbacr.put("julio@nu01.com", Set.of("premium"));
        googleIdentities.put("tok-work", "us-east-1:work");
        var key = streamKeyFor("work", "julio@nu01.com", "calm_quiet_otter");
        // Only its hash is kept, with who made it.
        var stored = streamKeys.get("profile_1/calm_quiet_otter");
        assertEquals(ProfileHandler.hash(key), stored.hash());
        assertEquals("julio@nu01.com", stored.createdBy());
        assertEquals("work", stored.subject());

        var response = profiles.handleRequest(streamerCall(key, "profile_1 calm_quiet_otter"), null);

        assertEquals(200, response.getStatusCode(), response.getBody());
        assertEquals("{\"identityId\":\"us-east-1:work\",\"token\":\"token-for-us-east-1:work\","
                + "\"deviceLimit\":50,\"devices\":[\"calm_quiet_otter\"],\"tier\":\"premium\","
                + "\"userId\":\"work\"}", response.getBody());
        assertEquals("premium", tiers.getLast());
        assertEquals(false, admins.getLast());
    }

    @Test
    void aFreeOwnersProfileStreamsFree() {
        googleIdentities.put("tok-work", "us-east-1:work");
        var key = streamKeyFor("work", "julio@nu01.com", "calm_quiet_otter");
        var response = profiles.handleRequest(streamerCall(key, "profile_1 calm_quiet_otter"), null);
        assertEquals(200, response.getStatusCode());
        assertTrue(response.getBody().contains("\"tier\":\"free\""), response.getBody());
    }

    @Test
    void aStreamKeyIsOnlyItsDevicesAndGoesWithIt() {
        googleIdentities.put("tok-work", "us-east-1:work");
        var key = streamKeyFor("work", "julio@nu01.com", "calm_quiet_otter");
        var other = streamKeyFor("work", "julio@nu01.com", "brave_little_lamp");
        for (var refused : List.of(
                streamerCall(other, "profile_1 calm_quiet_otter"),
                streamerCall(key, "profile_1 brave_little_lamp"),
                streamerCall(key, "profile_2 calm_quiet_otter"),
                streamerCall("psk_" + "A".repeat(43), "profile_1 calm_quiet_otter"),
                streamerCall("not-a-key", "profile_1 calm_quiet_otter"),
                streamerCall(null, "profile_1 calm_quiet_otter"))) {
            assertEquals(401, profiles.handleRequest(refused, null).getStatusCode());
        }
        assertEquals(400, profiles.handleRequest(streamerCall(key, "profile_1"), null).getStatusCode());
        assertEquals(400, profiles.handleRequest(streamerCall(key, "profile_1 Not/A/Device"), null).getStatusCode());

        // A new key replaces the old one.
        var newer = streamKeyFor("work", "julio@nu01.com", "calm_quiet_otter");
        assertEquals(401, profiles.handleRequest(streamerCall(key, "profile_1 calm_quiet_otter"), null).getStatusCode());
        assertEquals(200, profiles.handleRequest(streamerCall(newer, "profile_1 calm_quiet_otter"), null).getStatusCode());

        // Deleting the device revokes it.
        profiles.handleRequest(call("POST /api/auth/profile/devices/remove", "work", "julio@nu01.com",
                "calm_quiet_otter"), null);
        assertEquals(401, profiles.handleRequest(streamerCall(newer, "profile_1 calm_quiet_otter"), null).getStatusCode());
    }

    @Test
    void onlyMembersMakeStreamKeysForADevice() {
        var stranger = profiles.handleRequest(call("POST /api/auth/profile/stream-key", "x", "x@example.com",
                "calm_quiet_otter"), null);
        assertEquals(403, stranger.getStatusCode());
        var noDevice = profiles.handleRequest(call("POST /api/auth/profile/stream-key", "work", "julio@nu01.com",
                ""), null);
        assertEquals(400, noDevice.getStatusCode());
        assertTrue(streamKeys.isEmpty());
    }

    /** rbacr's roles in the presence system, by email: julio@ and ana@nu01.com are (free) members, others nothing. */
    private final Map<String, Set<String>> rbacr = new HashMap<>(Map.of(
            "julio@nu01.com", Set.of("free"), "ana@nu01.com", Set.of("free")));

    private final Roles roles = new Roles(e -> rbacr.getOrDefault(e, Set.of()));

    private ProfileHandler handler(boolean configured) {
        var profiles = new Profiles(store, clock, () -> "profile_" + (++ids));
        return new ProfileHandler(roles, profiles, backend, configured, new SecureRandom());
    }

    /** The profile {@code sub}'s subject is linked to. */
    private Profiles.Profile profileOf(String sub) {
        var id = store.links.get(GOOGLE + "#" + sub);
        return id == null ? null : store.profile(id);
    }

    private final ProfileHandler profiles = handler(true);

    @Test
    void anExistingUserKeepsTheFolderGoogleSignInGaveThem() {
        googleIdentities.put("tok-work", "us-east-1:work");
        foldersWithData.add("us-east-1:work");

        var response = profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);

        assertEquals(200, response.getStatusCode());
        assertEquals("{\"identityId\":\"us-east-1:work\",\"token\":\"token-for-us-east-1:work\","
                + "\"deviceLimit\":2,\"devices\":[],\"tier\":\"free\"}", response.getBody());
        var profile = profileOf("work");
        assertEquals("profile_1", profile.id());
        assertEquals(GOOGLE + "#work", profile.ownerSubject());
        assertEquals("julio@nu01.com", profile.ownerEmail());
        assertEquals("us-east-1:work", profile.identityId());
        assertEquals("profile_1", linked.get("us-east-1:work"));
        // The next call reuses the profile and its identity.
        profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        assertEquals(1, store.profiles.size());
        assertEquals(List.of("us-east-1:work|profile_1", "us-east-1:work|profile_1"), tokensIssued);
        // Each time, the identity may use live sync (AttachPolicy is idempotent).
        assertEquals(List.of("us-east-1:work", "us-east-1:work"), liveSyncAllowed);
    }

    @Test
    void credentialsNameTheBucketWhenItsConfigured() {
        googleIdentities.put("tok-work", "us-east-1:work");
        var withBucket = new ProfileHandler(roles, new Profiles(store, clock, () -> "profile_" + (++ids)), backend,
                true, new SecureRandom(), "presence-user-data-123");
        var response = withBucket.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        assertTrue(response.getBody().endsWith(",\"tier\":\"free\",\"bucket\":\"presence-user-data-123\"}"),
                response.getBody());
    }

    @Test
    void credentialsListTheProfilesDevicesInTheOrderTheyCame() {
        googleIdentities.put("tok-work", "us-east-1:work");
        var first = profiles.handleRequest(
                call("POST /api/auth/credentials", "work", "julio@nu01.com", "first_quiet_gadget"), null);
        assertTrue(first.getBody().contains(",\"deviceLimit\":2,\"devices\":[\"first_quiet_gadget\"],"),
                first.getBody());
        profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", "second_bold_lamp"), null);
        profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", "third_shy_kettle"), null);
        // Asking again keeps a device's place.
        var again = profiles.handleRequest(
                call("POST /api/auth/credentials", "work", "julio@nu01.com", "first_quiet_gadget"), null);
        assertTrue(again.getBody().contains(",\"devices\":[\"first_quiet_gadget\",\"second_bold_lamp\","
                + "\"third_shy_kettle\"],"), again.getBody());
        // Without a device (an older app), the list as it is.
        var none = profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        assertTrue(none.getBody().contains("\"third_shy_kettle\"]"), none.getBody());
        // Premium shows fifty.
        rbacr.put("julio@nu01.com", Set.of("premium"));
        var premium = profiles.handleRequest(
                call("POST /api/auth/credentials", "work", "julio@nu01.com", "first_quiet_gadget"), null);
        assertTrue(premium.getBody().contains(",\"deviceLimit\":50,"), premium.getBody());
    }

    @Test
    void aProfileListsAtMostFiftyDevices() {
        googleIdentities.put("tok-work", "us-east-1:work");
        String last = null;
        for (var i = 0; i < 51; i++) {
            var device = "device_" + (char) ('a' + i / 26) + (char) ('a' + i % 26) + "_lamp";
            last = profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", device), null)
                    .getBody();
        }
        assertEquals(50, store.devices.get("profile_1").size());
        assertFalse(last.contains("device_by_lamp"), last);
    }

    @Test
    void credentialsRefuseABodyThatIsntADeviceId() {
        for (var body : List.of("Not A Device", "a_b", "x".repeat(65), "{\"device\":\"a_b_c\"}")) {
            var response = profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", body), null);
            assertEquals(400, response.getStatusCode(), body);
        }
        assertTrue(tokensIssued.isEmpty());
    }

    @Test
    void aRemovedDeviceGivesItsPlaceToTheNext() {
        googleIdentities.put("tok-work", "us-east-1:work");
        for (var device : List.of("first_quiet_gadget", "second_bold_lamp", "third_shy_kettle")) {
            profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", device), null);
        }
        var removed = profiles.handleRequest(
                call("POST /api/auth/profile/devices/remove", "work", "julio@nu01.com", "second_bold_lamp"), null);
        assertEquals(200, removed.getStatusCode());
        assertEquals("{\"deviceLimit\":2,\"devices\":[\"first_quiet_gadget\",\"third_shy_kettle\"]}",
                removed.getBody());
        // Back again, it's last.
        var back = profiles.handleRequest(
                call("POST /api/auth/credentials", "work", "julio@nu01.com", "second_bold_lamp"), null);
        assertTrue(back.getBody().contains("[\"first_quiet_gadget\",\"third_shy_kettle\",\"second_bold_lamp\"]"),
                back.getBody());
        // Only a member, and only a device ID.
        assertEquals(403, profiles.handleRequest(
                call("POST /api/auth/profile/devices/remove", "home", "julio@gmail.com", "third_shy_kettle"), null)
                .getStatusCode());
        assertEquals(400, profiles.handleRequest(
                call("POST /api/auth/profile/devices/remove", "work", "julio@nu01.com", ""), null).getStatusCode());
    }

    @Test
    void credentialsNeedPresenceUser() {
        var response = profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertEquals(403, response.getStatusCode());
        assertTrue(tokensIssued.isEmpty());
        assertTrue(liveSyncAllowed.isEmpty());
        assertFalse(profileOf("home").hasIdentity());
    }

    @Test
    void aLinkedAccountGetsTheSameFolderAndMembershipButNotAdministration() {
        rbacr.put("julio@nu01.com", Set.of("admin"));
        googleIdentities.put("tok-work", "us-east-1:work");
        foldersWithData.add("us-east-1:work");
        var code = linkCode("work", "julio@nu01.com");

        var linkedResponse = profiles.handleRequest(
                call("POST /api/auth/profile/link", "home", "julio@gmail.com", " " + code.toLowerCase() + " "), null);
        assertEquals(200, linkedResponse.getStatusCode());
        // Shared from the admin owner: membership and premium, not administration.
        assertEquals("{\"profile\":\"profile_1\",\"shared\":[\"presence_premium\",\"presence_user\"],\"accounts\":["
                + "{\"email\":\"julio@nu01.com\",\"owner\":true,\"current\":false},"
                + "{\"email\":\"julio@gmail.com\",\"owner\":false,\"current\":true}]}", linkedResponse.getBody());

        // The gmail account now has nu01.com's folder, and in the listing
        // it asks at sign-in, its membership and premium, not administration.
        var response = profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertEquals(200, response.getStatusCode());
        assertTrue(response.getBody().contains("\"identityId\":\"us-east-1:work\""));
        assertTrue(listing("home", "julio@gmail.com").contains("\"shared\":[\"presence_premium\",\"presence_user\"]"));
        // The owner shares nothing with itself.
        assertTrue(listing("work", "julio@nu01.com").contains("\"shared\":[]"));
    }

    @Test
    void anOwnerWithoutRolesSharesNoMembership() {
        // rbacr gives mallory@nu01.com nothing.
        var event = call("POST /api/auth/profile/link-code", "mallory", "mallory@nu01.com", null);
        event.getRequestContext().getAuthorizer().getJwt().setClaims(Map.of("idp", GOOGLE, "idp_sub", "mallory",
                "email", "mallory@nu01.com", "email_verified", "true"));
        assertEquals(403, profiles.handleRequest(event, null).getStatusCode());
        // Even linked by hand, its accounts get nothing from it.
        var owner = profileOf("mallory");
        store.links.put(GOOGLE + "#home", owner.id());
        assertEquals(Set.of(), roles.of(Caller.of(Map.of("idp", GOOGLE, "idp_sub", "home",
                "email", "julio@gmail.com", "email_verified", "true")), store.profile(owner.id())));
    }

    @Test
    void theOwnersNewEmailCarriesItsRoles() {
        profiles.handleRequest(call("GET /api/auth/profile", "work", "julio@nu01.com", null), null);
        profiles.handleRequest(call("GET /api/auth/profile", "work", "julio@new.example", null), null);
        assertEquals("julio@new.example", profileOf("work").ownerEmail());
    }

    @Test
    void aRefusedLinkLeavesTheCodeUsable() {
        ownData("home", "julio@gmail.com", "us-east-1:home");
        var code = linkCode("work", "julio@nu01.com");
        assertEquals(409, link("home", "julio@gmail.com", code).getStatusCode());
        assertEquals(1, codes.size());
        // The data is moved away: the same code links.
        foldersWithData.remove("us-east-1:home");
        assertEquals(200, link("home", "julio@gmail.com", code).getStatusCode());
        assertTrue(codes.isEmpty());
        assertEquals(profileOf("work").id(), profileOf("home").id());
    }

    @Test
    void codesAreSingleUseAndExpire() {
        googleIdentities.put("tok-work", "us-east-1:work");
        var code = linkCode("work", "julio@nu01.com");
        assertTrue(Pattern.matches("[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}", code), code);
        assertEquals(200, link("home", "julio@gmail.com", code).getStatusCode());
        assertEquals(404, link("other", "ana@example.com", code).getStatusCode());

        var late = linkCode("work", "julio@nu01.com");
        clock = Clock.fixed(NOW.plus(ProfileHandler.CODE_TTL).plusSeconds(1), ZoneOffset.UTC);
        assertEquals(404, handler(true).handleRequest(
                call("POST /api/auth/profile/link", "other", "ana@example.com", late), null).getStatusCode());
        // Refused before anything is made for the caller.
        assertNull(profileOf("other"));
        assertEquals(400, link("other", "ana@example.com", "not a code").getStatusCode());
    }

    @Test
    void codesAreStoredOnlyAsHashes() {
        var code = linkCode("work", "julio@nu01.com").replace("-", "");
        assertFalse(codes.containsKey(code));
        assertTrue(codes.containsKey(ProfileHandler.hash(code)));
    }

    @Test
    void onlyMembersMakeCodes() {
        var response = profiles.handleRequest(call("POST /api/auth/profile/link-code", "home", "julio@gmail.com", null), null);
        assertEquals(403, response.getStatusCode());
        assertTrue(codes.isEmpty());
    }

    @Test
    void anAccountWithItsOwnDataIsntLinked() {
        ownData("home", "julio@gmail.com", "us-east-1:home");
        var code = linkCode("work", "julio@nu01.com");
        var response = link("home", "julio@gmail.com", code);
        assertEquals(409, response.getStatusCode());
        assertNotEquals(profileOf("work").id(), profileOf("home").id());
    }

    @Test
    void aProfileWithLinkedAccountsCantJoinAnother() {
        var first = linkCode("work", "julio@nu01.com");
        assertEquals(200, link("home", "julio@gmail.com", first).getStatusCode());
        var other = linkCode("ana", "ana@nu01.com");
        assertEquals(409, link("work", "julio@nu01.com", other).getStatusCode());
        // A linked (not owning) account may move.
        assertEquals(200, link("home", "julio@gmail.com", linkCode("ana", "ana@nu01.com")).getStatusCode());
        assertEquals(profileOf("ana").id(), profileOf("home").id());
    }

    @Test
    void unlinkingGivesTheAccountBackAProfileOfItsOwn() {
        googleIdentities.put("tok-work", "us-east-1:work");
        googleIdentities.put("tok-home", "us-east-1:home");
        assertEquals(200, link("home", "julio@gmail.com", linkCode("work", "julio@nu01.com")).getStatusCode());

        assertEquals(409, profiles.handleRequest(
                call("POST /api/auth/profile/unlink", "home", "julio@gmail.com", "julio@nu01.com"), null).getStatusCode());
        var response = profiles.handleRequest(
                call("POST /api/auth/profile/unlink", "work", "julio@nu01.com", "JULIO@gmail.com"), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"profile\":\"profile_1\",\"shared\":[],\"accounts\":["
                + "{\"email\":\"julio@nu01.com\",\"owner\":true,\"current\":true}]}", response.getBody());
        assertNull(store.links.get(GOOGLE + "#home"));
        assertEquals(404, profiles.handleRequest(
                call("POST /api/auth/profile/unlink", "work", "julio@nu01.com", "nobody@nu01.com"), null).getStatusCode());
        // Its next sign-in: a new profile it owns, on its own Google identity.
        var again = profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertEquals(403, again.getStatusCode(), "no roles of its own any more");
        assertEquals(GOOGLE + "#home", profileOf("home").ownerSubject());
    }

    @Test
    void theListingOfANewAccountIsJustItself() {
        var response = profiles.handleRequest(call("GET /api/auth/profile", "home", "Julio@Gmail.com", null), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"profile\":\"profile_1\",\"shared\":[],\"accounts\":["
                + "{\"email\":\"julio@gmail.com\",\"owner\":true,\"current\":true}]}", response.getBody());
    }

    @Test
    void withoutCloudSyncOnlyTheListingAnswers() {
        var off = handler(false);
        assertEquals(503, off.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null)
                .getStatusCode());
        assertEquals(503, off.handleRequest(call("POST /api/auth/profile/link-code", "work", "julio@nu01.com", null), null)
                .getStatusCode());
        assertEquals(200, off.handleRequest(call("GET /api/auth/profile", "work", "julio@nu01.com", null), null)
                .getStatusCode());
    }

    @Test
    void anUnverifiedEmailIsRefused() {
        var event = call("POST /api/auth/credentials", "work", "julio@nu01.com", null);
        event.getRequestContext().getAuthorizer().getJwt().setClaims(
                Map.of("idp", GOOGLE, "idp_sub", "work", "email", "julio@nu01.com", "email_verified", "false"));
        assertEquals(403, profiles.handleRequest(event, null).getStatusCode());
        assertTrue(store.links.isEmpty());
    }

    @Test
    void credentialsAreTaggedPremiumOnlyWhenRbacrSaysSo() {
        googleIdentities.put("tok-work", "us-east-1:work");
        // A free member: live sync only.
        var free = profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        assertEquals(200, free.getStatusCode());
        assertTrue(free.getBody().endsWith(",\"tier\":\"free\"}"), free.getBody());
        // rbacr's premium, or its admin: premium, the bucket too.
        rbacr.put("julio@nu01.com", Set.of("free", "premium"));
        var premium = profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        assertTrue(premium.getBody().endsWith(",\"tier\":\"premium\"}"), premium.getBody());
        rbacr.put("julio@nu01.com", Set.of("admin"));
        profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        // rbacr's free alone is free.
        rbacr.put("julio@nu01.com", Set.of("free"));
        profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        assertEquals(List.of("free", "premium", "premium", "free"), tiers);
    }

    @Test
    void theListingSaysWhatALinkedAccountSharesFromItsOwner() {
        // A free owner: membership only.
        assertEquals(200, link("home", "julio@gmail.com", linkCode("work", "julio@nu01.com")).getStatusCode());
        assertTrue(listing("home", "julio@gmail.com").startsWith(
                "{\"profile\":\"profile_1\",\"shared\":[\"presence_user\"],\"accounts\":["), listing("home", "julio@gmail.com"));
        // A premium owner: premium too, sorted.
        rbacr.put("julio@nu01.com", Set.of("premium"));
        assertTrue(listing("home", "julio@gmail.com").contains("\"shared\":[\"presence_premium\",\"presence_user\"]"));
        // A root owner: never root or admin.
        rbacr.put("julio@nu01.com", Set.of(Rbacr.ROOT, "admin"));
        assertTrue(listing("home", "julio@gmail.com").contains("\"shared\":[\"presence_premium\",\"presence_user\"]"));
        // An owner no longer a member: nothing.
        rbacr.remove("julio@nu01.com");
        assertTrue(listing("home", "julio@gmail.com").contains("\"shared\":[]"));
        // The owner itself, whatever it has: nothing shared.
        rbacr.put("julio@nu01.com", Set.of("premium"));
        assertTrue(listing("work", "julio@nu01.com").contains("\"shared\":[]"));
    }

    @Test
    void theListingMakesTheProfileAtTheFirstSignIn() {
        assertNull(profileOf("work"));
        var response = profiles.handleRequest(call("GET /api/auth/profile", "work", "julio@nu01.com", null), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("julio@nu01.com", profileOf("work").ownerEmail());
        // And finds the same one after.
        profiles.handleRequest(call("GET /api/auth/profile", "work", "julio@nu01.com", null), null);
        assertEquals(1, store.profiles.size());
    }

    @Test
    void onlyAnAdministratorsOwnCredentialsAreTaggedAdmin() {
        googleIdentities.put("tok-work", "us-east-1:work");
        rbacr.put("julio@nu01.com", Set.of("free"));
        profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        rbacr.put("julio@nu01.com", Set.of("admin"));
        profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);
        // A linked account shares the admin owner's membership, never the
        // administration: its credentials aren't tagged admin.
        var code = linkCode("work", "julio@nu01.com");
        profiles.handleRequest(call("POST /api/auth/profile/link", "home", "julio@gmail.com", code), null);
        profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertEquals(List.of(false, true, false), admins);
    }

    @Test
    void aLinkedAccountSharesItsOwnersPremium() {
        googleIdentities.put("tok-work", "us-east-1:work");
        rbacr.put("julio@nu01.com", Set.of("premium"));
        var code = linkCode("work", "julio@nu01.com");
        profiles.handleRequest(call("POST /api/auth/profile/link", "home", "julio@gmail.com", code), null);

        var response = profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertTrue(response.getBody().endsWith(",\"tier\":\"premium\"}"), response.getBody());
        // The owner's premium gone: the folder is free for both.
        rbacr.put("julio@nu01.com", Set.of("free"));
        response = profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertTrue(response.getBody().endsWith(",\"tier\":\"free\"}"), response.getBody());
    }

    @Test
    void premiumIsOnlyForAVerifiedEmail() {
        // Not for an unverified email, whatever rbacr says.
        assertEquals(Set.of(), roles.of("julio@gmail.com", false));
        rbacr.put("julio@gmail.com", Set.of("premium"));
        assertEquals(Set.of(), roles.of("julio@gmail.com", false));
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.of("julio@gmail.com", true));
    }

    @Test
    void aLinkedAccountSharesOnlyTheOwnersMembership() {
        var gmail = Caller.of(Map.of("idp", GOOGLE, "idp_sub", "home", "email", "julio@gmail.com", "email_verified", "true"));
        var owned = new Profiles.Profile("p", "", GOOGLE + "#work", "julio@nu01.com", "nu01.com");
        assertEquals(Set.of(), roles.of(gmail));
        assertEquals(Set.of(Roles.USER), roles.of(gmail, owned));
        var unverified = Caller.of(Map.of("idp", GOOGLE, "idp_sub", "home", "email", "julio@gmail.com",
                "email_verified", "false"));
        assertEquals(Set.of(), roles.of(unverified, owned));
        assertEquals(Set.of(), roles.of(gmail, null));
        assertEquals(Set.of(), roles.of(gmail, new Profiles.Profile("p", "", GOOGLE + "#work", null, null)));
        // An admin owner shares membership and premium, never the administration.
        var members = new Roles(e -> e.equals("ana@example.com") ? Set.of("admin") : Set.of());
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER),
                members.of(gmail, new Profiles.Profile("p", "", GOOGLE + "#ana", "ana@example.com", null)));
    }

    @Test
    void bearerTokens() {
        var event = new APIGatewayV2HTTPEvent();
        event.setHeaders(Map.of("authorization", "Bearer abc.def"));
        assertEquals("abc.def", Http.bearer(event));
        assertNull(ProfileHandler.normalizeCode(null));
        assertEquals("ABCDEFGH", ProfileHandler.normalizeCode("abcd-efgh"));
        assertNull(ProfileHandler.normalizeCode("ABCD-EFG0"));
    }

    private String linkCode(String sub, String email) {
        var response = profiles.handleRequest(call("POST /api/auth/profile/link-code", sub, email, null), null);
        assertEquals(201, response.getStatusCode(), response.getBody());
        var matcher = Pattern.compile("\"code\":\"([^\"]+)\"").matcher(response.getBody());
        assertTrue(matcher.find());
        assertNotNull(matcher.group(1));
        return matcher.group(1);
    }

    /** The {@code GET /api/auth/profile} answer for {@code sub}. */
    private String listing(String sub, String email) {
        var response = profiles.handleRequest(call("GET /api/auth/profile", sub, email, null), null);
        assertEquals(200, response.getStatusCode(), response.getBody());
        return response.getBody();
    }

    private com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse link(
            String sub, String email, String code) {
        return profiles.handleRequest(call("POST /api/auth/profile/link", sub, email, code), null);
    }

    @Test
    void aCognitoFailureSaysWhichServiceAndErrorWithoutAwsDetails() {
        googleIdentities.put("tok-work", "us-east-1:work");
        cognitoFails = CognitoIdentityException.builder()
                .statusCode(400)
                .message("arn:aws:cognito-identity:us-east-1:123456789012:identitypool/x is not authorized")
                .awsErrorDetails(AwsErrorDetails.builder()
                        .serviceName("CognitoIdentity")
                        .errorCode("AccessDeniedException")
                        .errorMessage("arn:aws:cognito-identity:us-east-1:123456789012:identitypool/x")
                        .build())
                .build();

        var response = profiles.handleRequest(call("POST /api/auth/credentials", "work", "julio@nu01.com", null), null);

        assertEquals(502, response.getStatusCode());
        assertEquals("{\"error\":\"the profile service failed\","
                + "\"cause\":\"CognitoIdentity AccessDeniedException (HTTP 400)\"}", response.getBody());
        assertFalse(response.getBody().contains("123456789012"));
    }

    @Test
    void aFailureNamesTheOperationAndAnEmulatorThatLacksIt() {
        var e = CognitoIdentityException.builder()
                .statusCode(400)
                .awsErrorDetails(AwsErrorDetails.builder()
                        .serviceName("CognitoIdentity")
                        .errorCode("UnknownOperationException")
                        .build())
                .build();
        e.setStackTrace(new StackTraceElement[] {
                new StackTraceElement("software.amazon.awssdk.core.internal.handler.BaseSyncClientHandler",
                        "execute", null, 1),
                new StackTraceElement("software.amazon.awssdk.services.cognitoidentity.DefaultCognitoIdentityClient",
                        "getId", null, 1),
                new StackTraceElement("presence.auth.ProfileBackend", "googleIdentity", null, 1),
        });

        assertEquals("CognitoIdentity GetId: UnknownOperationException (HTTP 400); "
                + "the endpoint doesn't implement it: a local AWS emulator (Floci, in the local"
                + " stack) has no CognitoIdentity, so this works only against AWS (the RC or"
                + " production)", Aws.cause(e));
    }

    @Test
    void anOtherFailureNamesItsType() {
        assertEquals("IllegalStateException", Aws.cause(new IllegalStateException("x")));
    }

    /** {@code sub} signs in, and its profile has an identity whose folder holds data. */
    private void ownData(String sub, String email, String identity) {
        profiles.handleRequest(call("GET /api/auth/profile", sub, email, null), null);
        store.identity(profileOf(sub).id(), identity);
        foldersWithData.add(identity);
    }

    /** A request the JWT authorizer let through: a session of Google account {@code sub}. */
    private static APIGatewayV2HTTPEvent call(String route, String sub, String email, String body) {
        var jwt = new APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT();
        var claims = RolesTest.verified(email);
        claims.put("idp", GOOGLE);
        claims.put("idp_sub", sub);
        jwt.setClaims(claims);
        var authorizer = new APIGatewayV2HTTPEvent.RequestContext.Authorizer();
        authorizer.setJwt(jwt);
        var context = new APIGatewayV2HTTPEvent.RequestContext();
        context.setAuthorizer(authorizer);
        var event = new APIGatewayV2HTTPEvent();
        event.setRequestContext(context);
        event.setRouteKey(route);
        event.setBody(body);
        return event;
    }
}
