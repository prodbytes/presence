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
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
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
        public VoucherHandler.Voucher find(String code) {
            return vouchers.get(code);
        }

        @Override
        public boolean delete(String code, boolean admins) {
            var v = vouchers.get(code);
            if (v != null && !admins && Roles.ADMIN.equals(v.role())) {
                return false;
            }
            vouchers.remove(code);
            return true;
        }

        @Override
        public VoucherHandler.Voucher claim(String code, String email, Instant now) {
            var v = vouchers.get(code);
            if (v == null || !v.redeemableBy(email, now) || v.discount() < VoucherHandler.FULL_DISCOUNT) {
                return null;
            }
            var redeemedBy = new HashSet<>(v.redeemedBy());
            redeemedBy.add(email);
            var claimed = new VoucherHandler.Voucher(v.code(), v.role(), v.startsAt(), v.expiresAt(), v.maxUses(),
                    v.uses() + 1, redeemedBy, v.createdBy(), v.createdAt(), v.discount());
            vouchers.put(code, claimed);
            return claimed;
        }

        @Override
        public void release(String code, String email) {
            var v = vouchers.get(code);
            if (v == null || !v.redeemedBy().contains(email)) {
                return;
            }
            var redeemedBy = new HashSet<>(v.redeemedBy());
            redeemedBy.remove(email);
            vouchers.put(code, new VoucherHandler.Voucher(v.code(), v.role(), v.startsAt(), v.expiresAt(), v.maxUses(),
                    v.uses() - 1, redeemedBy, v.createdBy(), v.createdAt(), v.discount()));
        }
    }

    /** The UserRoles table's miss counts, with the conditions of the DynamoDB lockout. */
    static final class MemoryLockout implements VoucherHandler.Lockout {
        final Map<String, Integer> misses = new HashMap<>();
        final Map<String, Instant> since = new HashMap<>();

        @Override
        public boolean locked(String email, Instant now) {
            var start = since.get(email);
            return start != null && misses.get(email) >= VoucherHandler.MAX_MISSES
                    && start.isAfter(now.minus(VoucherHandler.MISS_WINDOW));
        }

        @Override
        public void miss(String email, Instant now) {
            var start = since.get(email);
            if (start == null || !start.isAfter(now.minus(VoucherHandler.MISS_WINDOW))) {
                since.put(email, now);
                misses.put(email, 1);
            } else {
                misses.merge(email, 1, Integer::sum);
            }
        }
    }

    private final MemoryStore store = new MemoryStore();
    private final MemoryLockout lockout = new MemoryLockout();
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

    /** In rbacr, as its role names. */
    private final VoucherHandler redeem = new VoucherHandler(store, (email, role) -> {
        if (grantFails) {
            throw new IllegalStateException("rbacr is down");
        }
        granted.computeIfAbsent(email, e -> new TreeSet<>()).add(Roles.GRANTED_AS.get(role));
    }, lockout, clock);

    private final AdminHandler admin = new AdminHandler(
            // rbacr: the grants, and boss@nu01.com on its root list.
            new Roles(e -> e.equals("boss@nu01.com") ? Set.of(Rbacr.ROOT) : granted.getOrDefault(e, Set.of())),
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
        assertEquals("ABCD-EFGH-JK23", VoucherHandler.normalize("abcdefghjk23"));
        // Not a random code's shape: kept as typed (a chosen code).
        assertEquals("ABCD-EFGH-JK2", VoucherHandler.normalize("ABCD-EFGH-JK2"));
        assertEquals("ABCDEF-GHJK23", VoucherHandler.normalize("abcdef ghjk23"));
    }

    @Test
    void chosenCodesAreWordsAndDigits() {
        assertEquals("AUTUMN-OTTER-4821", VoucherHandler.normalize("  autumn otter_4821 "));
        assertEquals("AUTUMN-OTTER-4821", VoucherHandler.normalize("Autumn--Otter - 4821"));
        assertEquals("ABCD-EFGH-JK20", VoucherHandler.normalize("abcd-efgh-jk20"));
        assertNull(VoucherHandler.normalize("ABCDE"));
        assertNull(VoucherHandler.normalize("A".repeat(41)));
        assertNull(VoucherHandler.normalize("CAFÉ-OTTER-12"));
        assertNull(VoucherHandler.normalize("OTTER;DROP"));
        assertNull(VoucherHandler.normalize(" - - "));
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
        assertEquals("{\"code\":\"" + code + "\",\"role\":\"presence_user\",\"startsAt\":\"2026-10-04T12:00:00Z\",\"expiresAt\":\"2026-10-11T12:00:00Z\","
                + "\"maxUses\":5,\"uses\":0,\"redeemedBy\":[],\"createdBy\":\"boss@nu01.com\","
                + "\"createdAt\":\"2026-10-04T12:00:00Z\",\"discount\":100}", created.getBody());

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
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&discount=0",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&discount=101",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&discount=half",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&code=no",
                // Nine letters and digits: too few for a chosen code.
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&code=otter-4821",
                // An Admin voucher's code is always random.
                "role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=1&code=autumn-otter-4821",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&code=otter%3Bdrop",
                "role=presence_user&startsAt=autumn&expiresAt=2026-10-05T00:00:00Z&maxUses=1",
                "role=presence_user&startsAt=2026-10-05T00:00:00Z&expiresAt=2026-10-05T00:00:00Z&maxUses=1",
                "role=presence_user&startsAt=2026-11-01T00:00:00Z&expiresAt=2026-10-05T00:00:00Z&maxUses=1",
                "role=presence_user&startsAt=2025-10-02T00:00:00Z&expiresAt=2026-10-05T00:00:00Z&maxUses=1",
                "role=presence_user&startsAt=-1000000000-01-01T00:00:00Z&expiresAt=2026-10-05T00:00:00Z&maxUses=1",
        }) {
            assertEquals(400, create(body).getStatusCode(), body);
        }
        assertEquals(Map.of(), store.vouchers);
    }

    @Test
    void anAdminChoosesTheCodeAndDiscount() {
        var created = create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=3"
                + "&code=autumn+otter+4821&discount=25");
        assertEquals(201, created.getStatusCode());
        assertEquals("AUTUMN-OTTER-4821", code(created.getBody()));
        assertTrue(created.getBody().endsWith(",\"discount\":25}"), created.getBody());
        // Taken.
        assertEquals(409, create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1"
                + "&code=Autumn-Otter-4821").getStatusCode());
        assertEquals(25, store.vouchers.get("AUTUMN-OTTER-4821").discount());


        // A blank code is a random one.
        var random = create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&code=+");
        assertEquals(201, random.getStatusCode());
        assertTrue(code(random.getBody()).matches("[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}"));
    }

    @Test
    void aPartialDiscountGrantsNothingUntilPaid() {
        create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1&code=autumn-otter-4821&discount=25");
        var response = redeem.handleRequest(redeem("ana@example.com", "autumn otter 4821"), null);
        assertEquals(402, response.getStatusCode());
        assertEquals("{\"error\":\"the rest must be paid\",\"discount\":25}", response.getBody());
        // No role, and no use counted.
        assertNull(granted.get("ana@example.com"));
        assertEquals(0, store.vouchers.get("AUTUMN-OTTER-4821").uses());
        assertEquals(402, redeem.handleRequest(redeem("bob@example.com", "AUTUMN-OTTER-4821"), null)
                .getStatusCode());

        // Expired: the same 404 as any other code.
        now = Instant.parse("2026-10-05T00:00:00Z");
        assertEquals(404, redeem.handleRequest(redeem("ana@example.com", "AUTUMN-OTTER-4821"), null)
                .getStatusCode());
    }

    @Test
    void onlyRootsCreateAdminVouchers() {
        // An admin (not root) makes member vouchers only.
        granted.put("lead@example.com", Set.of("admin"));
        var admin = event("POST /api/auth/vouchers", "lead@example.com",
                "role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=1");
        assertEquals(403, this.admin.handleRequest(admin, null).getStatusCode());
        assertEquals(Map.of(), store.vouchers);
        var user = event("POST /api/auth/vouchers", "lead@example.com",
                "role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=1");
        assertEquals(201, this.admin.handleRequest(user, null).getStatusCode());

        // A root (boss@nu01.com) makes admin vouchers.
        assertEquals(201, create("role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=1").getStatusCode());
    }

    @Test
    void nobodyCreatesRootVouchers() {
        assertEquals(400, create("role=presence_root&expiresAt=2026-10-05T00:00:00Z&maxUses=1").getStatusCode());
        assertEquals(Map.of(), store.vouchers);
    }

    @Test
    void aUserRedeemsAVoucherForItsRole() {
        var code = code(create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=2").getBody());
        var response = redeem.handleRequest(redeem("Ana@Example.com", " " + code.toLowerCase().replace("-", " ") + " "),
                null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"role\":\"presence_user\",\"granted\":[\"presence_user\"],\"discount\":100}",
                response.getBody());
        assertEquals(Set.of("free"), granted.get("ana@example.com"));
        var voucher = store.vouchers.get(code);
        assertEquals(1, voucher.uses());
        assertEquals(Set.of("ana@example.com"), voucher.redeemedBy());
    }

    @Test
    void anAdminVoucherGrantsRbacrsAdmin() {
        var code = code(create("role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=1").getBody());
        var response = redeem.handleRequest(redeem("ana@example.com", code), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"role\":\"presence_admin\",\"granted\":[\"presence_admin\",\"presence_premium\","
                + "\"presence_user\"],\"discount\":100}", response.getBody());
        // rbacr's admin, which also makes her a member (and premium).
        assertEquals(Set.of("admin"), granted.get("ana@example.com"));
        // Now an admin herself, who can't pass the role on.
        assertEquals(200, admin.handleRequest(event("GET /api/auth/vouchers", "ana@example.com", null), null)
                .getStatusCode());
        assertEquals(403, admin.handleRequest(event("POST /api/auth/vouchers", "ana@example.com",
                "role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=1"), null).getStatusCode());
    }

    @Test
    void onlyRootsSeeAndDeleteAdminCodes() {
        var adminCode = code(create("role=presence_admin&expiresAt=2026-10-05T00:00:00Z&maxUses=5").getBody());
        now = NOW.plusSeconds(1);
        var memberCode = code(create("role=presence_user&expiresAt=2026-10-05T00:00:00Z&maxUses=5").getBody());
        granted.put("lead@example.com", Set.of("admin"));

        var list = admin.handleRequest(event("GET /api/auth/vouchers", "lead@example.com", null), null).getBody();
        assertTrue(list.contains("\"code\":\"" + memberCode + "\""), list);
        assertFalse(list.contains(adminCode), list);
        assertTrue(list.contains("{\"code\":null,\"hidden\":true,\"role\":\"presence_admin\""), list);
        // A root sees both.
        var rootList = admin.handleRequest(event("GET /api/auth/vouchers", "boss@nu01.com", null), null).getBody();
        assertTrue(rootList.contains(adminCode) && !rootList.contains("hidden"), rootList);

        assertEquals(403, admin.handleRequest(event("POST /api/auth/vouchers/delete", "lead@example.com", adminCode),
                null).getStatusCode());
        assertTrue(store.vouchers.containsKey(adminCode));
        assertEquals(200, admin.handleRequest(event("POST /api/auth/vouchers/delete", "lead@example.com", memberCode),
                null).getStatusCode());
        assertEquals(200, admin.handleRequest(event("POST /api/auth/vouchers/delete", "boss@nu01.com", adminCode),
                null).getStatusCode());
        assertEquals(Map.of(), store.vouchers);
    }

    @Test
    void tooManyWrongCodesLockTheEmailOutForAWhile() {
        var code = code(create("role=presence_user&expiresAt=2026-10-06T00:00:00Z&maxUses=5").getBody());
        var partial = code(create("role=presence_user&expiresAt=2026-10-06T00:00:00Z&maxUses=5"
                + "&code=autumn-otter-4821&discount=25").getBody());
        for (var i = 0; i < VoucherHandler.MAX_MISSES; i++) {
            // A partial-discount code is no miss.
            assertEquals(402, redeem.handleRequest(redeem("eve@example.com", partial), null).getStatusCode());
            assertEquals(404, redeem.handleRequest(redeem("eve@example.com", "WRONG-CODE-" + i), null)
                    .getStatusCode());
        }
        // Locked: even a good code waits, and nothing is counted or granted.
        var locked = redeem.handleRequest(redeem("eve@example.com", code), null);
        assertEquals(429, locked.getStatusCode());
        assertEquals("{\"error\":\"too many wrong codes; try again later\"}", locked.getBody());
        assertEquals(0, store.vouchers.get(code).uses());
        assertNull(granted.get("eve@example.com"));
        // Others aren't.
        assertEquals(200, redeem.handleRequest(redeem("ana@example.com", code), null).getStatusCode());

        // Once the window is over.
        now = NOW.plus(VoucherHandler.MISS_WINDOW).plusSeconds(1);
        assertEquals(200, redeem.handleRequest(redeem("eve@example.com", code), null).getStatusCode());
    }

    @Test
    void chosenCodesNeedTenLettersAndDigits() {
        assertEquals("AUTUMN-OTTER", VoucherHandler.chosen("autumn otter"));
        assertNull(VoucherHandler.chosen("OTTER-4821"));
        assertNull(VoucherHandler.chosen("A-B-C-D-E-F-G-H-I"));
        // Older, shorter codes are still redeemed and deleted.
        assertEquals("OTTER-4821", VoucherHandler.normalize("otter 4821"));
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
    void vouchersAreValidFromTheirStart() {
        // The season so far: valid at once.
        var season = create("role=presence_user&startsAt=2026-09-01T00%3A00%3A00Z"
                + "&expiresAt=2026-12-01T00%3A00%3A00Z&maxUses=5");
        assertEquals(201, season.getStatusCode());
        assertTrue(season.getBody().contains("\"startsAt\":\"2026-09-01T00:00:00Z\""), season.getBody());
        assertEquals(200, redeem.handleRequest(redeem("ana@example.com", code(season.getBody())), null)
                .getStatusCode());

        // Next season: not yet, the same 404 as any other code.
        var next = code(create("role=presence_user&startsAt=2026-12-01T00%3A00%3A00Z"
                + "&expiresAt=2027-03-01T00%3A00%3A00Z&maxUses=5&discount=25").getBody());
        assertEquals(404, redeem.handleRequest(redeem("bob@example.com", next), null).getStatusCode());
        now = Instant.parse("2026-12-01T00:00:00Z");
        assertEquals(402, redeem.handleRequest(redeem("bob@example.com", next), null).getStatusCode());
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
        var failed = redeem.handleRequest(redeem("ana@example.com", code), null);
        assertEquals(502, failed.getStatusCode());
        assertEquals("{\"error\":\"the voucher service failed\",\"cause\":\"IllegalStateException\"}",
                failed.getBody());
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
        var event = RolesTest.event(RolesTest.verified(email));
        event.setRouteKey(routeKey);
        event.setBody(body);
        return event;
    }
}
