package presence.auth;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.net.URI;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;

class RbacrTest {

    private Instant now = Instant.parse("2026-10-08T12:00:00Z");
    private final List<String> asked = new ArrayList<>();
    private Rbacr.Reply reply = new Rbacr.Reply(200, "{\"email\":\"ana@example.com\",\"globalRoles\":[],"
            + "\"roles\":{\"other\":[\"admin\"],\"presence\":[\"free\",\"premium\"]}}");
    private Exception fails;

    private final Rbacr rbacr = new Rbacr(URI.create("https://rbacr.example"), "rbacr_secret", "presence",
            (uri, token, body) -> {
                asked.add(uri + " " + token + " " + body);
                if (fails != null) {
                    throw fails;
                }
                return reply;
            },
            new Clock() {
                @Override
                public ZoneOffset getZone() {
                    return ZoneOffset.UTC;
                }

                @Override
                public Clock withZone(java.time.ZoneId zone) {
                    return this;
                }

                @Override
                public Instant instant() {
                    return now;
                }
            });

    @Test
    void asksForTheEmailsRolesInThePresenceSystem() {
        // Only the presence system's: another system's admin is nothing here.
        assertEquals(Set.of("free", "premium"), rbacr.apply(" Ana@Example.com "));
        // POST, the email in the body (not the URL), lower-cased; no systemId,
        // so the answer also says whether it's a root.
        assertEquals(List.of("https://rbacr.example/api/roles rbacr_secret {\"email\":\"ana@example.com\"}"), asked);
    }

    @Test
    void anRbacrRootGetsRoot() {
        reply = new Rbacr.Reply(200, "{\"email\":\"julio@nu01.com\",\"globalRoles\":[\"root\"],"
                + "\"roles\":{\"presence\":[\"admin\",\"free\",\"premium\"]}}");
        assertEquals(Set.of(Rbacr.ROOT, "admin", "free", "premium"), rbacr.apply("julio@nu01.com"));
    }

    @Test
    void withoutATokenNobodyHasRolesAndRbacrIsntAsked() {
        var none = new Rbacr(URI.create("https://rbacr.example"), null, "presence", (u, t, b) -> {
            throw new AssertionError("asked rbacr without a token");
        }, Clock.systemUTC());
        assertEquals(Set.of(), none.apply("ana@example.com"));
    }

    @Test
    void reusesAnAnswerForAMinute() {
        rbacr.apply("ana@example.com");
        now = now.plusSeconds(59);
        rbacr.apply("ANA@example.com");
        assertEquals(1, asked.size());
        now = now.plusSeconds(1);
        rbacr.apply("ana@example.com");
        assertEquals(2, asked.size());
    }

    @Test
    void failsClosedAndNeverCachesAFailure() {
        fails = new IOException("timed out");
        assertEquals(Set.of(), rbacr.apply("ana@example.com"));
        fails = null;
        reply = new Rbacr.Reply(401, "{\"error\":\"revoked\"}");
        assertEquals(Set.of(), rbacr.apply("ana@example.com"));
        reply = new Rbacr.Reply(200, "not json");
        assertEquals(Set.of(), rbacr.apply("ana@example.com"));
        // A one-system answer (with a systemId) isn't the one asked for.
        reply = new Rbacr.Reply(200, "{\"roles\":[\"premium\"]}");
        assertEquals(Set.of(), rbacr.apply("ana@example.com"));
        reply = new Rbacr.Reply(200, "{\"globalRoles\":[],\"roles\":{\"presence\":[\"premium\"]}}");
        assertEquals(Set.of("premium"), rbacr.apply("ana@example.com"));
        assertEquals(5, asked.size());
    }

    @Test
    void readsOnlyAWellFormedAnswer() {
        // No roles anywhere, or none in presence.
        assertEquals(Set.of(), Rbacr.roles("{\"globalRoles\":[],\"roles\":{}}", "presence"));
        assertEquals(Set.of(), Rbacr.roles("{\"globalRoles\":[],\"roles\":{\"other\":[\"free\"]}}", "presence"));
        assertEquals(Set.of("admin", "free"), Rbacr.roles(
                "{ \"globalRoles\" : [ ] , \"roles\" : { \"presence\" : [ \"admin\" , \"free\" ] , \"x\":[] } }", "presence"));
        // Root only from globalRoles, never as a system's role.
        assertEquals(Set.of(), Rbacr.roles("{\"globalRoles\":[],\"roles\":{\"presence\":[\"root\"]}}", "presence"));
        assertEquals(Set.of("root"), Rbacr.roles("{\"globalRoles\":[\"root\"],\"roles\":{}}", "presence"));
        assertNull(Rbacr.roles("{\"error\":\"no such system\"}", "presence"));
        assertNull(Rbacr.roles("{\"roles\":{\"presence\":[\"free\"]}}", "presence"));
        assertNull(Rbacr.roles("{\"globalRoles\":[],\"roles\":{\"presence\":[\"Premium\"]}}", "presence"));
        assertNull(Rbacr.roles("{\"globalRoles\":[],\"roles\":{\"presence\":[\"a\\\"b\"]}}", "presence"));
        assertNull(Rbacr.roles("{\"globalRoles\":[],\"roles\":{\"presence\":[1]}}", "presence"));
        assertNull(Rbacr.roles("{\"globalRoles\":[],\"roles\":{\"presence\":\"free\"}}", "presence"));
        assertNull(Rbacr.roles("{\"globalRoles\":[1],\"roles\":{}}", "presence"));
        assertNull(Rbacr.roles(null, "presence"));
    }
}
