package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class MembershipTest {

    private static final Instant NOW = Instant.parse("2026-09-27T12:00:00Z");

    /** The membership table: one request per email, with the handler's cooldown. */
    private final Map<String, MembershipHandler.Request> requests = new HashMap<>();
    private final List<MembershipHandler.Request> notified = new ArrayList<>();
    private final Set<String> dismissed = new java.util.HashSet<>();
    private RuntimeException notifyError;
    private final Map<String, Set<String>> granted = new HashMap<>();

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
            request -> {
                if (notifyError != null) {
                    throw notifyError;
                }
                notified.add(request);
            },
            Clock.fixed(NOW, ZoneOffset.UTC));

    private final AdminHandler admin = new AdminHandler(
            new Roles(Set.of("nu01.com"), Set.of(Roles.USER, Roles.ADMIN), e -> granted.getOrDefault(e, Set.of())),
            new AdminHandler.Backend() {
                @Override
                public List<MembershipHandler.Request> requests() {
                    return requests.values().stream().filter(r -> !dismissed.contains(r.email())).toList();
                }

                @Override
                public void grant(String email, String role) {
                    granted.computeIfAbsent(email, e -> new java.util.TreeSet<>()).add(role);
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
            });

    @Test
    void aVerifiedUserSendsARequest() {
        var response = membership.handleRequest(post("ana@example.com", "  Please let me in  "), null);
        assertEquals(202, response.getStatusCode());
        assertEquals("{\"requestedAt\":\"2026-09-27T12:00:00Z\"}", response.getBody());
        var request = requests.get("ana@example.com");
        assertEquals("Please let me in", request.message());
        assertEquals("Ana", request.name());
        assertEquals(List.of(request), notified);
        assertTrue(MembershipHandler.text(request)
                .startsWith("ana@example.com (Google profile name: Ana) asks for access"));
    }

    @Test
    void namesAreOneShortLine() {
        assertEquals("Ana  Bob", MembershipHandler.cleanName(" Ana\n\rBob\u0007"));
        assertEquals(100, MembershipHandler.cleanName("x".repeat(500)).length());
        assertEquals("", MembershipHandler.cleanName(null));
    }

    @Test
    void aFailedNotificationStillKeepsTheRequest() {
        notifyError = new IllegalStateException("SNS is down");
        assertEquals(202, membership.handleRequest(post("ana@example.com", "hi"), null).getStatusCode());
        assertEquals("hi", requests.get("ana@example.com").message());
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
        assertEquals(List.of(), notified);
    }

    @Test
    void aUserCanAskOncePerCooldown() {
        assertEquals(202, membership.handleRequest(post("ana@example.com", "one"), null).getStatusCode());
        assertEquals(409, membership.handleRequest(post("ana@example.com", "two"), null).getStatusCode());
        assertEquals("one", requests.get("ana@example.com").message());
        assertEquals(1, notified.size());
    }

    @Test
    void onlyAdminsUseTheAdminRoutes() {
        membership.handleRequest(post("ana@example.com", "hi"), null);
        var list = route("GET /api/auth/membership", "ana@example.com", null);
        assertEquals(403, admin.handleRequest(list, null).getStatusCode());
        var grant = route("POST /api/auth/membership/grant", "ana@example.com", "ana@example.com");
        assertEquals(403, admin.handleRequest(grant, null).getStatusCode());
        assertEquals(Map.of(), granted);

        // presence_admin without presence_user isn't enough (the app hides the screen too).
        granted.put("root@example.com", Set.of(Roles.ADMIN));
        assertEquals(403, admin.handleRequest(route("GET /api/auth/membership", "root@example.com", null), null)
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
        assertEquals(Set.of(Roles.USER), granted.get("ana@example.com"));
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
    void nu01UsersGetBothRolesAndOthersGetInOnlyOnceGranted() {
        var auth = new AuthHandler(new Roles(Set.of("nu01.com"), Set.of(Roles.USER, Roles.ADMIN),
                e -> granted.getOrDefault(e, Set.of())));
        var get = "GET /api/auth";
        assertEquals("{\"email\":\"boss@nu01.com\",\"roles\":[\"presence_admin\",\"presence_user\"]}",
                auth.handleRequest(route(get, "boss@nu01.com", null), null).getBody());
        assertEquals("{\"email\":\"ana@example.com\",\"roles\":[]}",
                auth.handleRequest(route(get, "ana@example.com", null), null).getBody());

        // Ana asks, and can't approve herself.
        assertEquals(202, membership.handleRequest(post("ana@example.com", "hi"), null).getStatusCode());
        assertEquals(403, admin.handleRequest(
                route("POST /api/auth/membership/grant", "ana@example.com", "ana@example.com"), null).getStatusCode());

        // An admin approves: Ana is a presence_user, not an admin.
        assertEquals(200, admin.handleRequest(
                route("POST /api/auth/membership/grant", "boss@nu01.com", "ana@example.com"), null).getStatusCode());
        assertEquals("{\"email\":\"ana@example.com\",\"roles\":[\"presence_user\"]}",
                auth.handleRequest(route(get, "ana@example.com", null), null).getBody());
        assertEquals(403, admin.handleRequest(route("GET /api/auth/membership", "ana@example.com", null), null)
                .getStatusCode());
    }

    private static APIGatewayV2HTTPEvent post(String email, String body) {
        return route("POST /api/auth/membership", email, body);
    }

    private static APIGatewayV2HTTPEvent route(String routeKey, String email, String body) {
        var event = RolesTest.event(new HashMap<>(Map.of("email", email, "email_verified", "true", "name", "Ana")));
        event.setRouteKey(routeKey);
        event.setBody(body);
        return event;
    }
}
