package presence.payments;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** {@code POST /api/payments/free}: Join free grants rbacr's free role, and nothing else. */
class JoinFreeTest {

    private static final String ANA = "ana@example.com";

    // rbacr: who holds free (directly, implied by premium or admin, or as a root), and what was asked.
    private final Set<String> members = new HashSet<>();
    private final List<String> calls = new ArrayList<>();
    private int status = 200;

    private final Web web = (method, uri, headers, body) -> {
        assertEquals("rbacr.example.com", uri.getHost());
        assertEquals("Bearer rbacr_grant", headers.get("authorization"));
        calls.add(method + " " + uri.getPath() + " " + body);
        if (status != 200) {
            return new Web.Reply(status, "{}");
        }
        var request = JsonReader.object(body);
        if (uri.getPath().equals("/api/check")) {
            assertEquals("presence", JsonReader.string(request, "systemId"));
            assertEquals("free", JsonReader.string(request, "role"));
            var allowed = members.contains(JsonReader.string(request, "email"));
            return new Web.Reply(200, "{\"allowed\":" + allowed + ",\"expiresAt\":null}");
        }
        assertEquals("POST", method);
        assertEquals("/api/systems/presence/grants", uri.getPath());
        // Only free, for good: no end, no other role.
        assertEquals("free", JsonReader.string(request, "role"));
        assertNull(JsonReader.string(request, "endsAt"));
        members.add(JsonReader.string(request, "grantee"));
        return new Web.Reply(201, "{}");
    };

    private StorePurchases purchases(boolean configured) {
        return new StorePurchases(new AppleStore(new FakeApple().verifier(), false), null,
                new RbacrGrants(URI.create("https://rbacr.example.com"), configured ? "rbacr_grant" : null,
                        "presence", web),
                new StorePurchasesTest.MemoryStore(), Clock.fixed(Instant.parse("2026-10-16T12:00:00Z"),
                ZoneOffset.UTC));
    }

    private static APIGatewayV2HTTPEvent event(String email, boolean verified, String body) {
        var claims = email == null ? Map.<String, String>of()
                : Map.of("email", email, "email_verified", Boolean.toString(verified));
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(StorePurchases.JOIN_FREE);
        event.setBody(body);
        event.setRequestContext(APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build());
        return event;
    }

    private APIGatewayV2HTTPResponse join(StorePurchases purchases, String email) {
        return purchases.handle(StorePurchases.JOIN_FREE, event(email, true, null));
    }

    @Test
    void grantsFreeForGoodToTheCallersVerifiedEmail() {
        var answer = join(purchases(true), " Ana@Example.com ");
        assertEquals(200, answer.getStatusCode());
        assertEquals("{\"member\":true,\"granted\":true}", answer.getBody());
        assertEquals(Set.of(ANA), members);
        assertEquals(2, calls.size());
        assertTrue(calls.get(1).startsWith("POST /api/systems/presence/grants {\"role\":\"free\",\"grantee\":"
                + "\"ana@example.com\"}"), calls.get(1));
    }

    @Test
    void isIdempotentForSomeoneWhoHoldsItAlready() {
        var purchases = purchases(true);
        assertEquals(200, join(purchases, ANA).getStatusCode());
        calls.clear();
        var again = join(purchases, ANA);
        assertEquals(200, again.getStatusCode());
        assertEquals("{\"member\":true,\"granted\":false}", again.getBody());
        // Asked, never granted again.
        assertEquals(1, calls.size());
        assertTrue(calls.getFirst().startsWith("POST /api/check "));
    }

    @Test
    void aMemberThroughAnotherRoleIsLeftAsIs() {
        // premium (a voucher's, the store's, Stripe's) or admin implies free in rbacr.
        members.add(ANA);
        var answer = join(purchases(true), ANA);
        assertEquals(200, answer.getStatusCode());
        assertEquals("{\"member\":true,\"granted\":false}", answer.getBody());
        assertEquals(1, calls.size());
    }

    @Test
    void theBodyNeverChoosesTheRoleOrTheGrantee() {
        var answer = purchases(true).handle(StorePurchases.JOIN_FREE,
                event(ANA, true, "{\"role\":\"admin\",\"grantee\":\"bea@example.com\"}"));
        assertEquals(200, answer.getStatusCode());
        assertEquals(Set.of(ANA), members);
    }

    @Test
    void needsAVerifiedEmail() {
        assertEquals(403, join(purchases(true), null).getStatusCode());
        assertEquals(403, purchases(true).handle(StorePurchases.JOIN_FREE, event(ANA, false, null))
                .getStatusCode());
        assertTrue(calls.isEmpty());
    }

    @Test
    void offWithoutAGrantToken() {
        var answer = join(purchases(false), ANA);
        assertEquals(503, answer.getStatusCode());
        assertTrue(calls.isEmpty());
    }

    @Test
    void rbacrFailingIs502() {
        status = 500;
        var answer = join(purchases(true), ANA);
        assertEquals(502, answer.getStatusCode());
        assertFalse(members.contains(ANA));
    }
}
