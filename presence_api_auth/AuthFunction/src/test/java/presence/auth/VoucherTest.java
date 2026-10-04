package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class VoucherTest {

    private static final Instant NOW = Instant.parse("2026-10-04T12:00:00Z");
    private static final Pattern CODE = Pattern.compile("\"code\":\"([A-Z0-9-]+)\"");

    /** The voucher table, with the conditions of the DynamoDB store. */
    static final class MemoryStore implements VoucherHandler.Store {
        final Map<String, VoucherHandler.Voucher> vouchers = new HashMap<>();

        @Override
        public boolean create(VoucherHandler.Voucher voucher) {
            return vouchers.putIfAbsent(voucher.code(), voucher) == null;
        }

        @Override
        public List<VoucherHandler.Voucher> all() {
            return new ArrayList<>(vouchers.values());
        }

        @Override
        public void delete(String code) {
            vouchers.remove(code);
        }

        @Override
        public String claim(String code, String email, Instant now) {
            var v = vouchers.get(code);
            if (v == null || !v.expiresAt().isAfter(now) || v.uses() >= v.maxUses()
                    || v.redeemedBy().contains(email)) {
                return null;
            }
            var redeemedBy = new HashSet<>(v.redeemedBy());
            redeemedBy.add(email);
            vouchers.put(code, new VoucherHandler.Voucher(v.code(), v.role(), v.expiresAt(), v.maxUses(),
                    v.uses() + 1, redeemedBy, v.createdBy(), v.createdAt()));
            return v.role();
        }

        @Override
        public void release(String code, String email) {
            var v = vouchers.get(code);
            if (v == null || !v.redeemedBy().contains(email)) {
                return;
            }
            var redeemedBy = new HashSet<>(v.redeemedBy());
            redeemedBy.remove(email);
            vouchers.put(code, new VoucherHandler.Voucher(v.code(), v.role(), v.expiresAt(), v.maxUses(),
                    v.uses() - 1, redeemedBy, v.createdBy(), v.createdAt()));
        }
    }

    private final MemoryStore store = new MemoryStore();
    private final Map<String, Set<String>> granted = new HashMap<>();
    private Instant now = NOW;
    private boolean grantFails;

    private final Clock clock = new Clock() {
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
    };

    private final VoucherHandler redeem = new VoucherHandler(store, (email, roles) -> {
        if (grantFails) {
            throw new IllegalStateException("DynamoDB is down");
        }
        granted.computeIfAbsent(email, e -> new TreeSet<>()).addAll(roles);
    }, clock);

    private final AdminHandler admin = new AdminHandler(
            new Roles(Set.of("nu01.com"), Set.of(Roles.USER, Roles.ADMIN), e -> granted.getOrDefault(e, Set.of())),
            new AdminHandler.Backend() {
                @Override
                public List<MembershipHandler.Request> requests() {
                    return List.of();
                }

                @Override
                public void grant(String email, String role) {
                }

                @Override
                public void remove(String email) {
                }

                @Override
                public void dismiss(String email) {
                }
            },
            store, clock);

    @Test
    void codesAreThreeGroupsOfFourAndTypedLoosely() {
        var code = VoucherHandler.newCode();
        assertTrue(code.matches("[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}"), code);
        assertEquals("ABCD-EFGH-JK23", VoucherHandler.normalize(" abcd efgh-jk23 "));
        assertNull(VoucherHandler.normalize("ABCD-EFGH-JK2"));
        // 0, O, 1 and I aren't used, so they can't be in a code.
        assertNull(VoucherHandler.normalize("ABCD-EFGH-JK20"));
        assertNull(VoucherHandler.normalize("ABCD-EFGH-JKIO"));
    }

    @Test
    void onlyAdminsManageVouchers() {
        for (var route : new String[] {"GET /api/auth/vouchers", "POST /api/auth/vouchers",
                "POST /api/auth/vouchers/delete"}) {
            var event = event(route, "ana@example.com", "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1");
            assertEquals(403, admin.handleRequest(event, null).getStatusCode(), route);
        }
        assertEquals(Map.of(), store.vouchers);
    }

    @Test
    void anAdminCreatesListsAndDeletesVouchers() {
        var created = create("role=presence_user&expiresAt=2026-10-11T12%3A00%3A00Z&maxUses=5");
        assertEquals(201, created.getStatusCode());
        var code = code(created.getBody());
        assertEquals("{\"code\":\"" + code + "\",\"role\":\"presence_user\",\"expiresAt\":\"2026-10-11T12:00:00Z\","
                + "\"maxUses\":5,\"uses\":0,\"redeemedBy\":[],\"createdBy\":\"boss@nu01.com\","
                + "\"createdAt\":\"2026-10-04T12:00:00Z\"}", created.getBody());

        now = NOW.plusSeconds(60);
        var second = code(create("role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=1").getBody());
        var list = admin.handleRequest(event("GET /api/auth/vouchers", "boss@nu01.com", null), null);
        assertEquals(200, list.getStatusCode());
        // Newest first.
        assertTrue(list.getBody().indexOf(second) < list.getBody().indexOf(code), list.getBody());

        var delete = admin.handleRequest(event("POST /api/auth/vouchers/delete", "boss@nu01.com",
                code.toLowerCase()), null);
        assertEquals(200, delete.getStatusCode());
        assertEquals(Set.of(second), store.vouchers.keySet());
        assertEquals(400, admin.handleRequest(event("POST /api/auth/vouchers/delete", "boss@nu01.com", "nope"), null)
                .getStatusCode());
    }

    @Test
    void vouchersNeedARoleAFutureExpiryAndUses() {
        for (var body : new String[] {
                "",
                "role=root&expiresAt=2026-10-05T00:00:00Z&maxUses=1",
                "role=presence_anonymous&expiresAt=2026-10-05T00:00:00Z&maxUses=1",
                "role=presence_user&expiresAt=tomorrow&maxUses=1",
                "role=presence_user&expiresAt=2026-10-04T12:00:00Z&maxUses=1",
                "role=presence_user&expiresAt=2027-10-06T00:00:00Z&maxUses=1",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=0",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1001",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=lots",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z",
        }) {
            assertEquals(400, create(body).getStatusCode(), body);
        }
        assertEquals(Map.of(), store.vouchers);
    }

    @Test
    void aUserRedeemsAVoucherForItsRole() {
        var code = code(create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=2").getBody());
        var response = redeem.handleRequest(redeem("Ana@Example.com", " " + code.toLowerCase().replace("-", " ") + " "),
                null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"role\":\"presence_user\",\"granted\":[\"presence_user\"]}", response.getBody());
        assertEquals(Set.of(Roles.USER), granted.get("ana@example.com"));
        var voucher = store.vouchers.get(code);
        assertEquals(1, voucher.uses());
        assertEquals(Set.of("ana@example.com"), voucher.redeemedBy());
    }

    @Test
    void anAdminVoucherAlsoGrantsPresenceUser() {
        var code = code(create("role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=1").getBody());
        assertEquals(200, redeem.handleRequest(redeem("ana@example.com", code), null).getStatusCode());
        assertEquals(Set.of(Roles.ADMIN, Roles.USER), granted.get("ana@example.com"));
        // Now an admin herself.
        assertEquals(200, admin.handleRequest(event("GET /api/auth/vouchers", "ana@example.com", null), null)
                .getStatusCode());
    }

    @Test
    void vouchersRunOutAndExpire() {
        var code = code(create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=2").getBody());
        assertEquals(200, redeem.handleRequest(redeem("ana@example.com", code), null).getStatusCode());
        // Once per user.
        assertEquals(404, redeem.handleRequest(redeem("ana@example.com", code), null).getStatusCode());
        assertEquals(200, redeem.handleRequest(redeem("bob@example.com", code), null).getStatusCode());
        // Used up.
        assertEquals(404, redeem.handleRequest(redeem("eve@example.com", code), null).getStatusCode());
        assertNull(granted.get("eve@example.com"));

        var later = code(create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=10").getBody());
        now = Instant.parse("2026-10-05T00:00:00Z");
        assertEquals(404, redeem.handleRequest(redeem("eve@example.com", later), null).getStatusCode());
        assertNull(granted.get("eve@example.com"));
    }

    @Test
    void unknownAndMalformedCodesAreRefused() {
        assertEquals(404, redeem.handleRequest(redeem("ana@example.com", "AAAA-BBBB-CCCC"), null).getStatusCode());
        assertEquals(404, redeem.handleRequest(redeem("ana@example.com", "let me in"), null).getStatusCode());
        assertEquals(400, redeem.handleRequest(redeem("ana@example.com", "  "), null).getStatusCode());
        assertEquals(400, redeem.handleRequest(redeem("ana@example.com", "x".repeat(10_000)), null).getStatusCode());
        assertEquals(Map.of(), granted);
    }

    @Test
    void redeemingNeedsAVerifiedEmail() {
        var code = code(create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1").getBody());
        var unverified = redeem("ana@example.com", code);
        unverified.getRequestContext().getAuthorizer().getJwt().getClaims().put("email_verified", "false");
        assertEquals(403, redeem.handleRequest(unverified, null).getStatusCode());
        assertEquals(403, redeem.handleRequest(new APIGatewayV2HTTPEvent(), null).getStatusCode());
        assertEquals(0, store.vouchers.get(code).uses());
    }

    @Test
    void aFailedGrantGivesTheUseBack() {
        var code = code(create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1").getBody());
        grantFails = true;
        assertThrows(IllegalStateException.class, () -> redeem.handleRequest(redeem("ana@example.com", code), null));
        assertEquals(0, store.vouchers.get(code).uses());
        grantFails = false;
        assertEquals(200, redeem.handleRequest(redeem("ana@example.com", code), null).getStatusCode());
    }

    @Test
    void formsAreDecoded() {
        assertEquals(Map.of("a", "1 2", "b", "", "c", "x=y"), VoucherHandler.form("a=1+2&b&c=x%3Dy&&d=%zz"));
    }

    private APIGatewayV2HTTPResponse create(String body) {
        return admin.handleRequest(event("POST /api/auth/vouchers", "boss@nu01.com", body), null);
    }

    private static String code(String body) {
        var matcher = CODE.matcher(body);
        assertTrue(matcher.find(), body);
        assertNotNull(matcher.group(1));
        return matcher.group(1);
    }

    private static APIGatewayV2HTTPEvent redeem(String email, String body) {
        return event("POST /api/auth/voucher", email, body);
    }

    private static APIGatewayV2HTTPEvent event(String routeKey, String email, String body) {
        var event = RolesTest.event(new HashMap<>(Map.of("email", email, "email_verified", "true", "name", "Ana")));
        event.setRouteKey(routeKey);
        event.setBody(body);
        return event;
    }
}
