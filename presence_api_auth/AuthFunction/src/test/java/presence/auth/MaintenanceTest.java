package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class MaintenanceTest {

    private static final Instant NOW = Instant.parse("2026-10-10T12:00:00Z");

    /** rbacr: adam is an admin, pat is premium, boss is on the root list. */
    private final Roles roles = new Roles(e -> switch (e) {
        case "adam@example.com" -> Set.of("admin");
        case "pat@example.com" -> Set.of("premium");
        case "boss@nu01.com" -> Set.of(Rbacr.ROOT);
        default -> Set.of();
    });

    private final Maintenance.Store store = Maintenance.memory();

    /** rbacr's flag on the presence system: null when rbacr can't be reached. */
    private Boolean rbacr = false;
    private final Maintenance.Flag flag = new Maintenance.Flag() {
        @Override
        public Boolean get() {
            return rbacr;
        }

        @Override
        public void set(boolean on) {
            if (rbacr == null) {
                throw new IllegalStateException("rbacr didn't answer a maintenance switch");
            }
            rbacr = on;
        }
    };

    private final AdminHandler admin = new AdminHandler(roles, subject -> null, null,
            new VoucherTest.MemoryStore(), store, flag, Clock.fixed(NOW, ZoneOffset.UTC));

    private final AuthHandler auth = new AuthHandler(roles, RolesTest.profiles(), ExecutionMode.RBAC,
            new Settings(true, true, true), store, flag);

    private String anonymous() {
        var body = auth.handleRequest(RolesTest.anonymous(), null).getBody();
        return body.substring(body.indexOf(",\"maintenance\":") + ",\"maintenance\":".length(), body.length() - 1);
    }

    @Test
    void rbacrDecides() {
        assertEquals("{\"on\":false,\"message\":\"\"}", anonymous());
        // A root switched it on in rbacr itself: no message from here.
        rbacr = true;
        assertEquals("{\"on\":true,\"message\":\"\",\"reason\":\"rbacr\"}", anonymous());
        rbacr = false;
        assertEquals("{\"on\":false,\"message\":\"\"}", anonymous());
    }

    @Test
    void anUnreachableRbacrIsMaintenance() {
        rbacr = null;
        assertEquals("{\"on\":true,\"message\":\"\",\"reason\":\"rbacr-unreachable\"}", anonymous());
        // Not an older switch's message: that's not why it's on.
        store.set(new Maintenance(true, "Back at 3pm", NOW, "boss@nu01.com"));
        assertEquals("{\"on\":true,\"message\":\"\",\"reason\":\"rbacr-unreachable\"}", anonymous());
        // Not in DEV, which asks no rbacr.
        var dev = new AuthHandler(roles, RolesTest.profiles(), ExecutionMode.DEV,
                new Settings(false, false, false), store, flag);
        assertTrue(dev.handleRequest(RolesTest.anonymous(), null).getBody()
                .endsWith(",\"maintenance\":{\"on\":false,\"message\":\"\"}}"));
    }

    @Test
    void aRootSwitchesRbacrsFlagAndEveryAppIsTold() {
        var response = admin.handleRequest(
                route("POST /api/auth/maintenance", "boss@nu01.com", "on=true&message=Back+at+3pm"), null);
        assertEquals(200, response.getStatusCode());
        assertEquals(true, rbacr);
        assertEquals("{\"on\":true,\"message\":\"Back at 3pm\",\"since\":" + NOW.toEpochMilli()
                + ",\"reason\":\"rbacr\",\"by\":\"boss@nu01.com\",\"rbacr\":true}", response.getBody());

        // The public answer doesn't say who.
        assertEquals("{\"on\":true,\"message\":\"Back at 3pm\",\"since\":" + NOW.toEpochMilli()
                + ",\"reason\":\"rbacr\"}", anonymous());
        assertEquals(response.getBody(),
                admin.handleRequest(route("GET /api/auth/maintenance", "boss@nu01.com", null), null).getBody());

        // Switched off in rbacr itself: off, whatever was switched here.
        rbacr = false;
        assertEquals("{\"on\":false,\"message\":\"\"}", anonymous());

        rbacr = true;
        admin.handleRequest(route("POST /api/auth/maintenance", "boss@nu01.com", "on=false"), null);
        assertEquals(false, rbacr);
        assertFalse(store.get().on());
        assertEquals("", store.get().message());
        // On again in rbacr itself: not when, and no message from here.
        rbacr = true;
        assertEquals("{\"on\":true,\"message\":\"\",\"reason\":\"rbacr\"}", anonymous());
    }

    @Test
    void anAdminSeesItButOnlyRootsSwitchIt() {
        rbacr = true;
        var seen = admin.handleRequest(route("GET /api/auth/maintenance", "adam@example.com", null), null);
        assertEquals(200, seen.getStatusCode());
        assertTrue(seen.getBody().startsWith("{\"on\":true,"));
        var response = admin.handleRequest(route("POST /api/auth/maintenance", "adam@example.com", "on=false"), null);
        assertEquals(403, response.getStatusCode());
        assertEquals(true, rbacr);
    }

    @Test
    void othersCantSeeOrSwitchIt() {
        for (var email : new String[]{"pat@example.com", "ana@example.com"}) {
            assertEquals(403, admin.handleRequest(route("POST /api/auth/maintenance", email, "on=true"), null)
                    .getStatusCode());
            assertEquals(403, admin.handleRequest(route("GET /api/auth/maintenance", email, null), null)
                    .getStatusCode());
        }
        assertEquals(false, rbacr);
    }

    @Test
    void anAdminSeesWhenRbacrCantSay() {
        rbacr = null;
        var body = admin.handleRequest(route("GET /api/auth/maintenance", "boss@nu01.com", null), null).getBody();
        assertTrue(body.contains("\"on\":true,"), body);
        assertTrue(body.contains("\"reason\":\"rbacr-unreachable\""), body);
        assertTrue(body.endsWith(",\"rbacr\":false}"), body);
        // And a switch fails without changing anything here.
        var response = admin.handleRequest(route("POST /api/auth/maintenance", "boss@nu01.com", "on=false"), null);
        assertEquals(502, response.getStatusCode());
        assertEquals(Maintenance.OFF, store.get());
    }

    @Test
    void theFormIsChecked() {
        assertEquals(400, admin.handleRequest(route("POST /api/auth/maintenance", "boss@nu01.com", "on=yes"), null)
                .getStatusCode());
        assertEquals(400, admin.handleRequest(route("POST /api/auth/maintenance", "boss@nu01.com", ""), null)
                .getStatusCode());
        var tooLong = "on=true&message=" + "a".repeat(Maintenance.MAX_MESSAGE + 1);
        assertEquals(400, admin.handleRequest(route("POST /api/auth/maintenance", "boss@nu01.com", tooLong), null)
                .getStatusCode());
        assertEquals(false, rbacr);
    }

    @Test
    void messagesKeepLineBreaksButNoOtherControlCharacters() {
        assertEquals("Back\nsoon", Maintenance.cleanMessage("  Back\n\u0007soon\t "));
        assertEquals("", Maintenance.cleanMessage(null));
        assertEquals(null, Maintenance.cleanMessage("x".repeat(Maintenance.MAX_MESSAGE + 1)));
    }

    @Test
    void anUnreadableMessageCostsOnlyTheMessage() {
        var failing = new Maintenance.Store() {
            @Override
            public Maintenance get() {
                throw new IllegalStateException("DynamoDB is down");
            }

            @Override
            public void set(Maintenance state) {
            }
        };
        rbacr = true;
        var response = new AuthHandler(roles, RolesTest.profiles(), ExecutionMode.RBAC,
                new Settings(true, true, true), failing, flag).handleRequest(RolesTest.anonymous(), null);
        assertEquals(200, response.getStatusCode());
        assertTrue(response.getBody().endsWith(",\"maintenance\":{\"on\":true,\"message\":\"\",\"reason\":\"rbacr\"}}"));
    }

    private static APIGatewayV2HTTPEvent route(String routeKey, String email, String body) {
        var event = RolesTest.event(RolesTest.verified(email));
        event.setRouteKey(routeKey);
        event.setBody(body);
        return event;
    }
}
