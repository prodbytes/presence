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

    private final AdminHandler admin = new AdminHandler(roles, subject -> null, null,
            new VoucherTest.MemoryStore(), store, Clock.fixed(NOW, ZoneOffset.UTC));

    private final AuthHandler auth = new AuthHandler(roles, RolesTest.profiles(), ExecutionMode.RBAC,
            new Settings(true, true, true), store);

    @Test
    void anAdminSwitchesItOnAndEveryAppIsTold() {
        var response = admin.handleRequest(
                route("POST /api/auth/maintenance", "adam@example.com", "on=true&message=Back+at+3pm"), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"on\":true,\"message\":\"Back at 3pm\",\"since\":" + NOW.toEpochMilli()
                + ",\"by\":\"adam@example.com\"}", response.getBody());

        // The public answer doesn't say who.
        var anonymous = auth.handleRequest(RolesTest.anonymous(), null).getBody();
        assertTrue(anonymous.endsWith(",\"maintenance\":{\"on\":true,\"message\":\"Back at 3pm\",\"since\":"
                + NOW.toEpochMilli() + "}}"), anonymous);
        assertFalse(anonymous.contains("adam"));

        assertEquals(response.getBody(),
                admin.handleRequest(route("GET /api/auth/maintenance", "boss@nu01.com", null), null).getBody());

        admin.handleRequest(route("POST /api/auth/maintenance", "boss@nu01.com", "on=false"), null);
        assertFalse(store.get().on());
        assertEquals("", store.get().message());
        assertEquals("boss@nu01.com", store.get().by());
    }

    @Test
    void onlyAdminsSwitchIt() {
        for (var email : new String[]{"pat@example.com", "ana@example.com"}) {
            var response = admin.handleRequest(route("POST /api/auth/maintenance", email, "on=true"), null);
            assertEquals(403, response.getStatusCode());
            assertEquals(403, admin.handleRequest(route("GET /api/auth/maintenance", email, null), null)
                    .getStatusCode());
        }
        assertFalse(store.get().on());
    }

    @Test
    void theFormIsChecked() {
        assertEquals(400, admin.handleRequest(route("POST /api/auth/maintenance", "adam@example.com", "on=yes"), null)
                .getStatusCode());
        assertEquals(400, admin.handleRequest(route("POST /api/auth/maintenance", "adam@example.com", ""), null)
                .getStatusCode());
        var tooLong = "on=true&message=" + "a".repeat(Maintenance.MAX_MESSAGE + 1);
        assertEquals(400, admin.handleRequest(route("POST /api/auth/maintenance", "adam@example.com", tooLong), null)
                .getStatusCode());
        assertFalse(store.get().on());
    }

    @Test
    void messagesKeepLineBreaksButNoOtherControlCharacters() {
        assertEquals("Back\nsoon", Maintenance.cleanMessage("  Back\n\u0007soon\t "));
        assertEquals("", Maintenance.cleanMessage(null));
        assertEquals(null, Maintenance.cleanMessage("x".repeat(Maintenance.MAX_MESSAGE + 1)));
    }

    @Test
    void anUnreadableStateIsOffSoTheStartCheckStillAnswers() {
        var failing = new Maintenance.Store() {
            @Override
            public Maintenance get() {
                throw new IllegalStateException("DynamoDB is down");
            }

            @Override
            public void set(Maintenance state) {
            }
        };
        var response = new AuthHandler(roles, RolesTest.profiles(), ExecutionMode.RBAC,
                new Settings(true, true, true), failing).handleRequest(RolesTest.anonymous(), null);
        assertEquals(200, response.getStatusCode());
        assertTrue(response.getBody().endsWith(",\"maintenance\":{\"on\":false,\"message\":\"\"}}"));
    }

    private static APIGatewayV2HTTPEvent route(String routeKey, String email, String body) {
        var event = RolesTest.event(RolesTest.verified(email));
        event.setRouteKey(routeKey);
        event.setBody(body);
        return event;
    }
}
