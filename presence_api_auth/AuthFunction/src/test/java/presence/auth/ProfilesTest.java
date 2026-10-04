package presence.auth;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ProfilesTest {

    private static final String GOOGLE = "https://accounts.google.com";
    private static final Instant NOW = Instant.parse("2026-10-02T12:00:00Z");

    private final MemoryProfiles store = new MemoryProfiles();
    private final AtomicInteger next = new AtomicInteger();
    private final Profiles profiles = new Profiles(store, Clock.fixed(NOW, ZoneOffset.UTC),
            () -> "profile-" + next.incrementAndGet());

    @Test
    void aFirstSignInCreatesAProfileAndTheNextFindsIt() {
        assertEquals("profile-1", profiles.of(GOOGLE, "111", "ana@example.com"));
        assertEquals(Map.of(GOOGLE + "#111", "profile-1"), store.links);
        assertEquals(Map.of("profile-1", NOW), store.profiles);

        assertEquals("profile-1", profiles.of(GOOGLE, "111", "ana@example.com"));
        assertEquals(1, next.get());
    }

    @Test
    void theSubjectNotTheEmailFindsTheProfile() {
        var first = profiles.of(GOOGLE, "111", "ana@example.com");
        // The same account with a new email: the same profile.
        assertEquals(first, profiles.of(GOOGLE, "111", "ana@new.example"));
        // Another account with the old email: a profile of its own.
        assertEquals("profile-2", profiles.of(GOOGLE, "222", "ana@example.com"));
        // The same sub from another issuer is another subject.
        assertEquals("profile-3", profiles.of("https://login.example", "111", "ana@example.com"));
    }

    @Test
    void subjectsLinkedToAProfileShareIt() {
        var profile = profiles.of(GOOGLE, "111", "ana@example.com");
        store.links.put("https://login.example#ana", profile);
        assertEquals(profile, profiles.of("https://login.example", "ana", "ana@example.org"));
        assertEquals(1, next.get());
    }

    @Test
    void whenTwoFirstSignInsRaceTheFirstLinkWins() {
        var racing = new Profiles(new MemoryProfiles() {
            @Override
            public String linked(String subject) {
                // The other sign-in links between this one's read and its write.
                var found = super.linked(subject);
                if (found == null && !links.containsKey(subject)) {
                    links.put(subject, "theirs");
                    return null;
                }
                return found;
            }
        }, Clock.fixed(NOW, ZoneOffset.UTC), () -> "mine");
        assertEquals("theirs", racing.of(GOOGLE, "111", null));
    }

    @Test
    void aLinkWhoseProfileIsMissingGetsItBack() {
        store.links.put(GOOGLE + "#111", "orphan");
        assertEquals("orphan", profiles.of(GOOGLE, "111", null));
        assertEquals(Set.of("orphan"), store.profiles.keySet());
    }

    @Test
    void aTakenIdIsNeverReused() {
        store.profiles.put("profile-1", Instant.EPOCH);
        store.profiles.put("profile-2", Instant.EPOCH);
        assertEquals("profile-3", profiles.of(GOOGLE, "111", null));
        assertEquals(Instant.EPOCH, store.profiles.get("profile-1"));

        var unlucky = new Profiles(store, Clock.fixed(NOW, ZoneOffset.UTC), () -> "profile-1");
        assertThrows(IllegalStateException.class, () -> unlucky.of(GOOGLE, "222", null));
        assertNull(store.links.get(GOOGLE + "#222"));
    }

    @Test
    void idsAreTwoDifferentAdjectivesAndAnAnimal() {
        assertTrue(ProfileId.ADJECTIVES.size() >= 1000);
        assertTrue(ProfileId.ANIMALS.size() >= 1000);
        assertTrue(ProfileId.combinations() > 1_000_000_000L);
        for (var words : List.of(ProfileId.ADJECTIVES, ProfileId.ANIMALS)) {
            assertEquals(words.size(), Set.copyOf(words).size());
            assertTrue(words.stream().allMatch(w -> w.matches("[a-z]+")));
        }
        var random = new Random(7);
        var seen = new HashSet<String>();
        for (var i = 0; i < 5_000; i++) {
            var id = ProfileId.generate(random);
            assertTrue(ProfileId.PATTERN.matcher(id).matches(), id);
            var parts = id.split("_");
            assertNotEquals(parts[0], parts[1]);
            assertTrue(ProfileId.ANIMALS.contains(parts[2]), id);
            seen.add(id);
        }
        // About 0.01 expected repeats in 5,000 (Profiles still refuses them).
        assertTrue(seen.size() >= 4_998);
        assertTrue(ProfileId.PATTERN.matcher(ProfileId.generate()).matches());
    }

    @Test
    void noSubjectNoProfile() {
        assertNull(profiles.of(GOOGLE, null, "ana@example.com"));
        assertNull(profiles.of(null, "111", "ana@example.com"));
        assertNull(profiles.of(GOOGLE, " ", "ana@example.com"));
        assertEquals(Map.of(), store.links);
        assertEquals(Map.of(), store.profiles);
    }

    @Test
    void theHandlerAnswersWithTheProfile() {
        var handler = new AuthHandler(new Roles(Set.of("nu01.com"), Set.of(), e -> Set.of()), profiles);
        var claims = Map.of("iss", GOOGLE, "sub", "111", "email", "ana@nu01.com", "email_verified", "true");
        var body = "{\"email\":\"ana@nu01.com\",\"profile\":\"profile-1\",\"roles\":[\"presence_admin\",\"presence_root\",\"presence_user\"]}";
        assertEquals(body, handler.handleRequest(RolesTest.event(claims), null).getBody());
        assertEquals(body, handler.handleRequest(RolesTest.event(claims), null).getBody());
        // Users without roles have a profile too.
        assertEquals("{\"email\":\"bob@example.com\",\"profile\":\"profile-2\",\"roles\":[]}",
                handler.handleRequest(RolesTest.event(Map.of("iss", GOOGLE, "sub", "222",
                        "email", "bob@example.com", "email_verified", "true")), null).getBody());
        // The anonymous route makes none.
        var anonymous = new com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent();
        anonymous.setRouteKey(AuthHandler.ANONYMOUS_ROUTE);
        handler.handleRequest(anonymous, null);
        assertEquals(2, store.links.size());
    }
}
