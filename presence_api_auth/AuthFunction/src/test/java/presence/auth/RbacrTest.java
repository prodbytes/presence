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
    private Rbacr.Reply reply = new Rbacr.Reply(200,
            "{\"email\":\"ana@example.com\",\"systemId\":\"presence\",\"roles\":[\"free\",\"premium\"]}");
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
        assertEquals(Set.of("free", "premium"), rbacr.apply(" Ana@Example.com "));
        // POST, the email in the body (not the URL), lower-cased.
        assertEquals(List.of("https://rbacr.example/api/roles rbacr_secret "
                + "{\"email\":\"ana@example.com\",\"systemId\":\"presence\"}"), asked);
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
        reply = new Rbacr.Reply(200, "{\"roles\":[\"premium\"]}");
        assertEquals(Set.of("premium"), rbacr.apply("ana@example.com"));
        assertEquals(4, asked.size());
    }

    @Test
    void readsOnlyAWellFormedRolesList() {
        assertEquals(Set.of(), Rbacr.roles("{\"roles\":[]}"));
        assertEquals(Set.of("admin", "free"), Rbacr.roles("{\"roles\": [ \"admin\" , \"free\" ]}"));
        assertNull(Rbacr.roles("{\"error\":\"no such system\"}"));
        assertNull(Rbacr.roles("{\"roles\":[\"Premium\"]}"));
        assertNull(Rbacr.roles("{\"roles\":[\"a\\\"b\"]}"));
        assertNull(Rbacr.roles("{\"roles\":[1]}"));
        assertNull(Rbacr.roles(null));
    }
}
