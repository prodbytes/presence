package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;

class MembershipTest {

    private static final Instant NOW = Instant.parse("2026-09-27T12:00:00Z");

    /** The membership table: one request per email, with the handler's cooldown. */
    private final Map<String, MembershipHandler.Request> requests = new HashMap<>();
    private final Set<String> dismissed = new java.util.HashSet<>();
    /** rbacr's grants (its role names), as the admin routes make them. */
    private final Map<String, Set<String>> granted = new HashMap<>();

    /** rbacr: the grants, and boss@nu01.com on its root list. */
    private final Roles roles = new Roles(e -> {
        var held = new java.util.TreeSet<>(granted.getOrDefault(e, Set.of()));
        if (e.equals("boss@nu01.com")) {
            held.add(Rbacr.ROOT);
        }
        return held;
    });

    private final MembershipHandler membership = new MembershipHandler(
            (request, notBefore) -> {
                var last = requests.get(request.email());
                if (last != null && !last.requestedAt().isBefore(notBefore)) {
                    return false;
                }
                requests.put(request.email(), request);
                dismissed.remove(request.email());
                return true;
            },
            Clock.fixed(NOW, ZoneOffset.UTC));

    private final AdminHandler admin = new AdminHandler(
            roles,
            new AdminHandler.Backend() {
                @Override
                public List<MembershipHandler.Request> requests() {
                    return requests.values().stream().filter(r -> !dismissed.contains(r.email())).toList();
                }

                @Override
                public void grant(String email, String role) {
                    granted.computeIfAbsent(email, e -> new java.util.TreeSet<>()).add(Roles.GRANTED_AS.get(role));
                }

                @Override
                public void remove(String email) {
                    requests.remove(email);
                }

                @Override
                public void dismiss(String email) {
                    if (requests.containsKey(email)) {
                        dismissed.add(email);
                    }
                }
            },
            new VoucherTest.MemoryStore(),
            Clock.fixed(NOW, ZoneOffset.UTC));

    @Test
    void aVerifiedUserSendsARequest() {
        var response = membership.handleRequest(post("ana@example.com", "  Please let me in  "), null);
        assertEquals(202, response.getStatusCode());
        assertEquals("{\"requestedAt\":\"2026-09-27T12:00:00Z\"}", response.getBody());
        var request = requests.get("ana@example.com");
        assertEquals("Please let me in", request.message());
        assertEquals("Ana", request.name());
    }

    @Test
    void namesAreOneShortLine() {
        assertEquals("Ana  Bob", MembershipHandler.cleanName(" Ana\n\rBob\u0007"));
        assertEquals(100, MembershipHandler.cleanName("x".repeat(500)).length());
        assertEquals("", MembershipHandler.cleanName(null));
    }

    @Test
    void base64BodiesAreDecoded() {
        var event = post("ana@example.com", Base64.getEncoder().encodeToString("Olá".getBytes(StandardCharsets.UTF_8)));
        event.setIsBase64Encoded(true);
        assertEquals(202, membership.handleRequest(event, null).getStatusCode());
        assertEquals("Olá", requests.get("ana@example.com").message());
    }

    @Test
    void requestsNeedAVerifiedEmailAndAMessage() {
        var unverified = post("ana@example.com", "hi");
        unverified.getRequestContext().getAuthorizer().getJwt().getClaims().put("email_verified", "false");
        assertEquals(403, membership.handleRequest(unverified, null).getStatusCode());
        assertEquals(403, membership.handleRequest(new APIGatewayV2HTTPEvent(), null).getStatusCode());
        assertEquals(400, membership.handleRequest(post("ana@example.com", "   "), null).getStatusCode());
        assertEquals(400, membership.handleRequest(
                post("ana@example.com", "x".repeat(MembershipHandler.MAX_MESSAGE + 1)), null).getStatusCode());
        assertEquals(400, membership.handleRequest(post("ana@example.com", "x".repeat(1_000_000)), null)
                .getStatusCode());
        assertEquals(Map.of(), requests);
    }

    @Test
    void aUserCanAskOncePerCooldown() {
        assertEquals(202, membership.handleRequest(post("ana@example.com", "one"), null).getStatusCode());
        assertEquals(409, membership.handleRequest(post("ana@example.com", "two"), null).getStatusCode());
        assertEquals("one", requests.get("ana@example.com").message());
    }

    @Test
    void onlyAdminsUseTheAdminRoutes() {
        membership.handleRequest(post("ana@example.com", "hi"), null);
        var list = route("GET /api/auth/membership", "ana@example.com", null);
        assertEquals(403, admin.handleRequest(list, null).getStatusCode());
        var grant = route("POST /api/auth/membership/grant", "ana@example.com", "ana@example.com");
        assertEquals(403, admin.handleRequest(grant, null).getStatusCode());
        assertEquals(Map.of(), granted);

        // Premium isn't enough: only rbacr's admin (or a root) administers.
        granted.put("pat@example.com", Set.of("premium"));
        assertEquals(403, admin.handleRequest(route("GET /api/auth/membership", "pat@example.com", null), null)
                .getStatusCode());
    }

    @Test
    void anAdminListsAndGrantsRequests() {
        membership.handleRequest(post("ana@example.com", "hi \"there\""), null);
        var list = admin.handleRequest(route("GET /api/auth/membership", "boss@nu01.com", null), null);
        assertEquals(200, list.getStatusCode());
        assertEquals("{\"requests\":[{\"email\":\"ana@example.com\",\"name\":\"Ana\","
                + "\"message\":\"hi \\\"there\\\"\",\"requestedAt\":\"2026-09-27T12:00:00Z\"}]}", list.getBody());

        var grant = admin.handleRequest(
                route("POST /api/auth/membership/grant", "boss@nu01.com", " ANA@example.com "), null);
        assertEquals(200, grant.getStatusCode());
        // In rbacr, as free.
        assertEquals(Set.of("free"), granted.get("ana@example.com"));
        assertEquals(Map.of(), requests);
    }

    @Test
    void anAdminDismissesRequests() {
        membership.handleRequest(post("ana@example.com", "hi"), null);
        var dismiss = admin.handleRequest(
                route("POST /api/auth/membership/dismiss", "boss@nu01.com", "ana@example.com"), null);
        assertEquals(200, dismiss.getStatusCode());
        assertEquals(Map.of(), granted);
        var list = admin.handleRequest(route("GET /api/auth/membership", "boss@nu01.com", null), null);
        assertEquals("{\"requests\":[]}", list.getBody());
        // Dismissing doesn't reset the requester's cooldown.
        assertEquals(409, membership.handleRequest(post("ana@example.com", "again"), null).getStatusCode());
    }

    @Test
    void grantsNeedAnEmail() {
        for (var body : new String[] {"", "nobody", "@example.com", "a@", "a b@example.com", "a@x.com,b@y.com"}) {
            var response = admin.handleRequest(route("POST /api/auth/membership/grant", "boss@nu01.com", body), null);
            assertEquals(400, response.getStatusCode(), body);
        }
        assertEquals(404, admin.handleRequest(route("GET /api/auth/other", "boss@nu01.com", null), null)
                .getStatusCode());
        assertEquals(Map.of(), granted);
    }

    @Test
    void rbacrRootsGetEveryRoleAndOthersGetInOnlyOnceGranted() {
        var auth = new AuthHandler(roles, RolesTest.profiles());
        var get = "GET /api/auth";
        assertEquals("{\"email\":\"boss@nu01.com\",\"profile\":null,\"roles\":[\"presence_admin\","
                        + "\"presence_premium\",\"presence_root\",\"presence_user\"]}",
                auth.handleRequest(route(get, "boss@nu01.com", null), null).getBody());
        assertEquals("{\"email\":\"ana@example.com\",\"profile\":null,\"roles\":[]}",
                auth.handleRequest(route(get, "ana@example.com", null), null).getBody());

        // Ana asks, and can't approve herself.
        assertEquals(202, membership.handleRequest(post("ana@example.com", "hi"), null).getStatusCode());
        assertEquals(403, admin.handleRequest(
                route("POST /api/auth/membership/grant", "ana@example.com", "ana@example.com"), null).getStatusCode());

        // An admin approves: Ana is a presence_user, not an admin.
        assertEquals(200, admin.handleRequest(
                route("POST /api/auth/membership/grant", "boss@nu01.com", "ana@example.com"), null).getStatusCode());
        assertEquals("{\"email\":\"ana@example.com\",\"profile\":null,\"roles\":[\"presence_user\"]}",
                auth.handleRequest(route(get, "ana@example.com", null), null).getBody());
        assertEquals(403, admin.handleRequest(route("GET /api/auth/membership", "ana@example.com", null), null)
                .getStatusCode());
    }

    private static APIGatewayV2HTTPEvent post(String email, String body) {
        return route("POST /api/auth/membership", email, body);
    }

    private static APIGatewayV2HTTPEvent route(String routeKey, String email, String body) {
        var event = RolesTest.event(RolesTest.verified(email));
        event.setRouteKey(routeKey);
        event.setBody(body);
        return event;
    }
}
