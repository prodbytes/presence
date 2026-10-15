package presence.payments;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PaymentsTest {

    private static final String MONTHLY = "https://buy.stripe.com/dRm9AT6F71VfbaN1tl2Ji03";
    private static final String YEARLY = "https://buy.stripe.com/test_yearly00";
    private static final String PRO_MONTHLY = "https://buy.stripe.com/test_promonthly00";

    private PaymentLinks saved;
    private final List<String> asked = new ArrayList<>();
    private Map<String, Set<String>> roles = Map.of(
            "boss@example.com", Set.of("free", "premium", "admin"),
            "root@example.com", Set.of("root"),
            "ana@example.com", Set.of("free"));
    private RuntimeException fails;

    private final LinkStore store = new LinkStore() {
        @Override
        public Optional<PaymentLinks> load() {
            if (fails != null) {
                throw fails;
            }
            return Optional.ofNullable(saved);
        }

        @Override
        public void save(PaymentLinks links) {
            saved = links;
        }
    };

    private final PaymentsHandler handler = new PaymentsHandler(store, PaymentLinks.defaults(MONTHLY, ""),
            email -> {
                asked.add(email);
                return roles.getOrDefault(email, Set.of());
            },
            Clock.fixed(Instant.ofEpochMilli(1_790_000_000_000L), ZoneOffset.UTC), null);

    private static APIGatewayV2HTTPEvent event(String route, String email, boolean verified, String body) {
        var claims = email == null ? Map.<String, String>of()
                : Map.of("email", email, "email_verified", Boolean.toString(verified));
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(route);
        event.setBody(body);
        event.setRequestContext(APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build());
        return event;
    }

    private static String put(String monthly, String yearly) {
        return "{\"monthly\":\"" + monthly + "\",\"yearly\":\"" + yearly + "\"}";
    }

    @Test
    void answersTheDeploysDefaultsUntilAnAdminSaves() {
        var reply = handler.handleRequest(event(PaymentsHandler.GET_LINKS, "ana@example.com", true, null), null);
        assertEquals(200, reply.getStatusCode());
        assertEquals("{\"monthly\":\"" + MONTHLY + "\",\"yearly\":\"\",\"proMonthly\":\"\",\"proYearly\":\"\","
                + "\"saved\":false}", reply.getBody());
        assertEquals("no-store", reply.getHeaders().get("Cache-Control"));
        // Reading needs no role.
        assertTrue(asked.isEmpty());
    }

    @Test
    void anAdminSavesTheLinks() {
        var reply = handler.handleRequest(
                event(PaymentsHandler.PUT_LINKS, "Boss@Example.com", true, put(MONTHLY, YEARLY)), null);
        assertEquals(200, reply.getStatusCode());
        assertEquals(List.of("boss@example.com"), asked);
        assertEquals(new PaymentLinks(MONTHLY, YEARLY, 1_790_000_000_000L, "boss@example.com"), saved);

        var read = handler.handleRequest(event(PaymentsHandler.GET_LINKS, "ana@example.com", true, null), null);
        assertEquals("{\"monthly\":\"" + MONTHLY + "\",\"yearly\":\"" + YEARLY
                + "\",\"proMonthly\":\"\",\"proYearly\":\"\",\"saved\":true,\"updatedAt\":1790000000000}",
                read.getBody());
        // Who saved them stays in the table.
        assertFalse(read.getBody().contains("boss"));
    }

    @Test
    void anAdminSavesProsLinksAndAnOlderAppKeepsThem() {
        var body = "{\"monthly\":\"" + MONTHLY + "\",\"yearly\":\"\",\"proMonthly\":\"" + PRO_MONTHLY
                + "\",\"proYearly\":\"\"}";
        assertEquals(200, handler.handleRequest(event(PaymentsHandler.PUT_LINKS, "boss@example.com", true, body), null)
                .getStatusCode());
        assertEquals(new PaymentLinks(MONTHLY, "", PRO_MONTHLY, "", 1_790_000_000_000L, "boss@example.com"), saved);
        var read = handler.handleRequest(event(PaymentsHandler.GET_LINKS, "ana@example.com", true, null), null);
        assertTrue(read.getBody().contains(",\"proMonthly\":\"" + PRO_MONTHLY + "\",\"proYearly\":\"\","),
                read.getBody());
        // An older app's editor sends Premium's only: Pro's stay.
        assertEquals(200, handler.handleRequest(
                event(PaymentsHandler.PUT_LINKS, "boss@example.com", true, put(MONTHLY, YEARLY)), null).getStatusCode());
        assertEquals(new PaymentLinks(MONTHLY, YEARLY, PRO_MONTHLY, "", 1_790_000_000_000L, "boss@example.com"), saved);
        // Pro's links are Stripe's too.
        var bad = "{\"monthly\":\"\",\"yearly\":\"\",\"proMonthly\":\"https://evil.example/x\",\"proYearly\":\"\"}";
        assertEquals(400, handler.handleRequest(event(PaymentsHandler.PUT_LINKS, "boss@example.com", true, bad), null)
                .getStatusCode());
        // Pro's alone isn't a body.
        var proOnly = "{\"proMonthly\":\"\",\"proYearly\":\"\"}";
        assertEquals(400, handler.handleRequest(event(PaymentsHandler.PUT_LINKS, "boss@example.com", true, proOnly), null)
                .getStatusCode());
    }

    @Test
    void anRbacrRootSavesToo() {
        var reply = handler.handleRequest(event(PaymentsHandler.PUT_LINKS, "root@example.com", true, put("", YEARLY)),
                null);
        assertEquals(200, reply.getStatusCode());
        assertEquals("", saved.monthly());
    }

    @Test
    void othersMayNotSave() {
        for (var event : List.of(
                event(PaymentsHandler.PUT_LINKS, "ana@example.com", true, put(MONTHLY, YEARLY)),
                // An admin's email Google hasn't verified is nobody's.
                event(PaymentsHandler.PUT_LINKS, "boss@example.com", false, put(MONTHLY, YEARLY)),
                event(PaymentsHandler.PUT_LINKS, null, true, put(MONTHLY, YEARLY)))) {
            assertEquals(403, handler.handleRequest(event, null).getStatusCode());
        }
        assertNull(saved);
    }

    @Test
    void onlyStripeLinks() {
        for (var link : List.of("http://buy.stripe.com/x", "https://buy.stripe.com.evil.example/x",
                "https://evilstripe.com/x", "https://buy.stripe.com/x?a=b", "javascript:alert(1)",
                "https://buy.stripe.com/" + "x".repeat(600))) {
            var reply = handler.handleRequest(
                    event(PaymentsHandler.PUT_LINKS, "boss@example.com", true, put(link, "")), null);
            assertEquals(400, reply.getStatusCode(), link);
        }
        for (var body : List.of("", "{}", "{\"monthly\":\"\"}", put("", "") + "x",
                "{\"monthly\":\"\",\"yearly\":\"\",\"other\":\"\"}", "{\"monthly\":\"\",\"monthly\":\"\"}",
                "{\"monthly\":\"a\\\"b\",\"yearly\":\"\"}")) {
            var reply = handler.handleRequest(event(PaymentsHandler.PUT_LINKS, "boss@example.com", true, body), null);
            assertEquals(400, reply.getStatusCode(), body);
        }
        assertNull(saved);
    }

    @Test
    void theDefaultsMustBeLinksToo() {
        assertEquals(new PaymentLinks("", MONTHLY, 0, null),
                PaymentLinks.defaults("https://example.com/pay", " " + MONTHLY + " "));
    }

    @Test
    void aStoreFailureIs502() {
        fails = new IllegalStateException("down");
        assertEquals(502, handler.handleRequest(event(PaymentsHandler.GET_LINKS, "ana@example.com", true, null), null)
                .getStatusCode());
    }

    @Test
    void unknownRoutes404() {
        assertEquals(404, handler.handleRequest(event("DELETE /api/payments/links", "boss@example.com", true, null),
                null).getStatusCode());
    }
}
