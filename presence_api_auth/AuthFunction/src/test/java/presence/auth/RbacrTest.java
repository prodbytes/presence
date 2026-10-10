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
import static org.junit.jupiter.api.Assertions.assertThrows;

class RbacrTest {

    private Instant now = Instant.parse("2026-10-08T12:00:00Z");
    private final List<String> asked = new ArrayList<>();
    private Rbacr.Reply reply = new Rbacr.Reply(200, "{\"email\":\"ana@example.com\",\"globalRoles\":[],"
            + "\"roles\":{\"other\":[\"admin\"],\"presence\":[\"free\",\"premium\"]}}");
    private Exception fails;
    /** rbacr's health check: its status, or why it doesn't answer; how often it was asked. */
    private int healthStatus = 200;
    private Exception healthFails;
    private int health;

    private final Rbacr rbacr = new Rbacr(URI.create("https://rbacr.example"), "rbacr_secret", "presence",
            (method, uri, token, body) -> {
                if (uri.getPath().equals("/health")) {
                    // rbacr's public health check: never with the token.
                    assertNull(token);
                    if (healthFails != null) {
                        throw healthFails;
                    }
                    health++;
                    return new Rbacr.Reply(healthStatus, "{\"status\":\"ok\"}");
                }
                asked.add((method.equals("POST") ? "" : method + " ") + uri + " " + token + " " + body);
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
    void grantsARoleInThePresenceSystem() {
        reply = new Rbacr.Reply(201, "{\"systemId\":\"presence\",\"role\":\"free\"}");
        rbacr.grant(" Ana@Example.com ", "free");
        assertEquals(List.of("https://rbacr.example/api/systems/presence/grants rbacr_secret "
                + "{\"role\":\"free\",\"grantee\":\"ana@example.com\"}"), asked);
    }

    @Test
    void aGrantForgetsTheOldAnswer() {
        assertEquals(Set.of("free", "premium"), rbacr.apply("ana@example.com"));
        reply = new Rbacr.Reply(201, "{}");
        rbacr.grant("ana@example.com", "admin");
        reply = new Rbacr.Reply(200, "{\"globalRoles\":[],\"roles\":{\"presence\":[\"admin\",\"free\",\"premium\"]}}");
        assertEquals(Set.of("admin", "free", "premium"), rbacr.apply("ana@example.com"));
        assertEquals(3, asked.size());
    }

    @Test
    void aRefusedOrFailedGrantThrows() {
        reply = new Rbacr.Reply(403, "{\"error\":\"Only roots manage\"}");
        assertThrows(IllegalStateException.class, () -> rbacr.grant("ana@example.com", "free"));
        fails = new IOException("timed out");
        assertThrows(IllegalStateException.class, () -> rbacr.grant("ana@example.com", "free"));
        // Unconfigured: nobody has roles, nothing is granted.
        var none = new Rbacr(URI.create("https://rbacr.example"), null, "presence", (m, u, t, b) -> {
            throw new AssertionError("asked rbacr without a token");
        }, Clock.systemUTC());
        assertEquals(Set.of(), none.apply("ana@example.com"));
        assertThrows(IllegalStateException.class, () -> none.grant("ana@example.com", "free"));
        assertNull(none.maintenance(), "unconfigured: it can't say");
        assertThrows(IllegalStateException.class, () -> none.setMaintenance(true));
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

    @Test
    void asksTheSystemsMaintenanceFlagAndReusesItBriefly() {
        reply = new Rbacr.Reply(200, "{\"id\":\"presence\",\"name\":\"Presence\",\"roles\":[\"free\"],"
                + "\"implies\":{},\"maintenance\":true}");
        assertEquals(true, rbacr.maintenance());
        assertEquals(List.of("GET https://rbacr.example/api/systems/presence rbacr_secret null"), asked);
        reply = new Rbacr.Reply(200, "{\"id\":\"presence\",\"maintenance\":false}");
        assertEquals(true, rbacr.maintenance(), "reused");
        now = now.plus(Rbacr.MODE_CACHE_FOR);
        assertEquals(false, rbacr.maintenance());
        assertEquals(2, asked.size());
    }

    @Test
    void cantTellTheFlagWhenRbacrIsDownRefusesOrAnswersSomethingElse() {
        fails = new IOException("timed out");
        assertNull(rbacr.maintenance());
        // Reused too: a down rbacr isn't waited for at every app start.
        fails = null;
        reply = new Rbacr.Reply(200, "{\"id\":\"presence\",\"maintenance\":false}");
        assertNull(rbacr.maintenance());
        for (var answer : List.of(new Rbacr.Reply(503, "{}"), new Rbacr.Reply(401, "{\"error\":\"no\"}"),
                new Rbacr.Reply(200, "{\"id\":\"other\",\"maintenance\":false}"), new Rbacr.Reply(200, "nope"))) {
            now = now.plus(Rbacr.MODE_CACHE_FOR);
            reply = answer;
            assertNull(rbacr.maintenance(), answer.toString());
        }
        // An rbacr from before maintenance mode: the system, without the flag.
        now = now.plus(Rbacr.MODE_CACHE_FOR);
        reply = new Rbacr.Reply(200, "{\"id\":\"presence\",\"roles\":[]}");
        assertEquals(false, rbacr.maintenance());
    }

    @Test
    void aFailingHealthCheckIsMaintenanceWithoutAskingTheFlag() {
        reply = new Rbacr.Reply(200, "{\"id\":\"presence\",\"maintenance\":false}");
        assertEquals(false, rbacr.maintenance());
        assertEquals(1, health, "the health check, with the flag");
        healthStatus = 503;
        now = now.plus(Rbacr.MODE_CACHE_FOR);
        assertNull(rbacr.maintenance());
        healthStatus = 200;
        healthFails = new IOException("timed out");
        now = now.plus(Rbacr.MODE_CACHE_FOR);
        assertNull(rbacr.maintenance());
        assertEquals(1, asked.size(), "the flag isn't asked of an unhealthy rbacr");
        healthFails = null;
        now = now.plus(Rbacr.MODE_CACHE_FOR);
        assertEquals(false, rbacr.maintenance());
    }

    @Test
    void switchesTheFlag() {
        reply = new Rbacr.Reply(200, "{\"id\":\"presence\",\"maintenance\":true}");
        rbacr.setMaintenance(true);
        assertEquals(List.of("PATCH https://rbacr.example/api/systems/presence rbacr_secret {\"maintenance\":true}"),
                asked);
        assertEquals(true, rbacr.maintenance(), "known from the switch");
        assertEquals(1, asked.size());
        reply = new Rbacr.Reply(403, "{}");
        assertThrows(IllegalStateException.class, () -> rbacr.setMaintenance(false));
        fails = new IOException("timed out");
        assertThrows(IllegalStateException.class, () -> rbacr.setMaintenance(false));
    }
}
