package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

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
    /** Google ID token -> the identity it signs in to directly (GetId). */
    private final Map<String, String> googleIdentities = new HashMap<>();
    /** Identity -> the developer identifier (profile) linked to it. */
    private final Map<String, String> linked = new HashMap<>();
    private final Set<String> foldersWithData = new HashSet<>();
    private final List<String> tokensIssued = new ArrayList<>();
    private Clock clock = Clock.fixed(NOW, ZoneOffset.UTC);
    private int ids;

    private final ProfileHandler.Backend backend = new ProfileHandler.Backend() {
        @Override
        public void saveCode(String hash, ProfileHandler.LinkCode code) {
            codes.put(hash, code);
        }

        @Override
        public Optional<ProfileHandler.LinkCode> takeCode(String hash, Instant now) {
            var code = codes.remove(hash);
            return code == null || !code.expiresAt().isAfter(now) ? Optional.empty() : Optional.of(code);
        }

        @Override
        public String googleIdentity(String googleIdToken) {
            return googleIdentities.computeIfAbsent(googleIdToken, t -> "us-east-1:new-" + googleIdentities.size());
        }

        @Override
        public String openIdToken(String identityId, String profileId) {
            // As Cognito: a developer identifier belongs to one identity.
            var was = linked.putIfAbsent(identityId, profileId);
            assertTrue(was == null || was.equals(profileId), "identity " + identityId + " relinked");
            tokensIssued.add(identityId + "|" + profileId);
            return "token-for-" + identityId;
        }

        @Override
        public boolean folderEmpty(String identityId) {
            return !foldersWithData.contains(identityId);
        }
    };

    /** nu01.com gets both roles; julio@gmail.com and others none. */
    private final Roles roles = new Roles(Set.of("nu01.com"), Set.of(Roles.USER, Roles.ADMIN), e -> Set.of());

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
        assertEquals("{\"identityId\":\"us-east-1:work\",\"token\":\"token-for-us-east-1:work\"}", response.getBody());
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
    }

    @Test
    void credentialsNeedPresenceUser() {
        var response = profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertEquals(403, response.getStatusCode());
        assertTrue(tokensIssued.isEmpty());
        assertFalse(profileOf("home").hasIdentity());
    }

    @Test
    void aLinkedAccountGetsTheSameFolderAndRoles() {
        googleIdentities.put("tok-work", "us-east-1:work");
        foldersWithData.add("us-east-1:work");
        var code = linkCode("work", "julio@nu01.com");

        var linkedResponse = profiles.handleRequest(
                call("POST /api/auth/profile/link", "home", "julio@gmail.com", " " + code.toLowerCase() + " "), null);
        assertEquals(200, linkedResponse.getStatusCode());
        assertEquals("{\"profile\":\"profile_1\",\"accounts\":["
                + "{\"email\":\"julio@nu01.com\",\"owner\":true,\"current\":false},"
                + "{\"email\":\"julio@gmail.com\",\"owner\":false,\"current\":true}]}", linkedResponse.getBody());

        // The gmail account now has nu01.com's roles and folder, here and in GET /api/auth.
        var response = profiles.handleRequest(call("POST /api/auth/credentials", "home", "julio@gmail.com", null), null);
        assertEquals(200, response.getStatusCode());
        assertTrue(response.getBody().contains("\"identityId\":\"us-east-1:work\""));
        var auth = new AuthHandler(roles, new Profiles(store, clock, () -> "unused"));
        assertEquals("{\"email\":\"julio@gmail.com\",\"profile\":\"profile_1\","
                        + "\"roles\":[\"presence_admin\",\"presence_user\"]}",
                auth.handleRequest(call("GET /api/auth", "home", "julio@gmail.com", null), null).getBody());
        // And the Admin routes, which never make a profile.
        assertEquals("julio@nu01.com", AuthHandler.ownerOf(AuthHandler.owners(new Profiles(store)),
                Map.of("iss", GOOGLE, "sub", "home")));
        assertNull(AuthHandler.ownerOf(AuthHandler.owners(new Profiles(store)), Map.of("iss", GOOGLE, "sub", "nobody")));
        assertNull(store.links.get(GOOGLE + "#nobody"));
    }

    @Test
    void theOwnersNewEmailCarriesItsRoles() {
        profiles.handleRequest(call("GET /api/auth/profile", "work", "julio@nu01.com", null), null);
        profiles.handleRequest(call("GET /api/auth/profile", "work", "julio@new.example", null), null);
        assertEquals("julio@new.example", profileOf("work").ownerEmail());
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
        googleIdentities.put("tok-home", "us-east-1:home");
        foldersWithData.add("us-east-1:home");
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
        assertEquals("{\"profile\":\"profile_1\",\"accounts\":["
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
        assertEquals("{\"profile\":\"profile_1\",\"accounts\":["
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
                Map.of("iss", GOOGLE, "sub", "work", "email", "julio@nu01.com", "email_verified", "false"));
        assertEquals(403, profiles.handleRequest(event, null).getStatusCode());
        assertTrue(store.links.isEmpty());
    }

    @Test
    void anOwnerLinkedAccountSharesTheOwnersRoles() {
        assertEquals(Set.of(), roles.of("julio@gmail.com", true));
        assertEquals(Set.of(Roles.ADMIN, Roles.USER), roles.of("julio@gmail.com", true, "julio@nu01.com"));
        assertEquals(Set.of(), roles.of("julio@gmail.com", false, "julio@nu01.com"));
        assertEquals(Set.of(), roles.of("julio@gmail.com", true, null));
    }

    @Test
    void bearerTokens() {
        var event = new APIGatewayV2HTTPEvent();
        event.setHeaders(Map.of("authorization", "Bearer abc.def"));
        assertEquals("abc.def", ProfileHandler.bearer(event));
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

    private com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse link(
            String sub, String email, String code) {
        return profiles.handleRequest(call("POST /api/auth/profile/link", sub, email, code), null);
    }

    /** A request the JWT authorizer let through: Google account {@code sub}, its token {@code tok-<sub>}. */
    private static APIGatewayV2HTTPEvent call(String route, String sub, String email, String body) {
        var jwt = new APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT();
        jwt.setClaims(Map.of("iss", GOOGLE, "sub", sub, "email", email, "email_verified", "true"));
        var authorizer = new APIGatewayV2HTTPEvent.RequestContext.Authorizer();
        authorizer.setJwt(jwt);
        var context = new APIGatewayV2HTTPEvent.RequestContext();
        context.setAuthorizer(authorizer);
        var event = new APIGatewayV2HTTPEvent();
        event.setRequestContext(context);
        event.setRouteKey(route);
        event.setHeaders(Map.of("authorization", "Bearer tok-" + sub));
        event.setBody(body);
        return event;
    }
}
