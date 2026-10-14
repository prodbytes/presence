package presence.payments;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.security.KeyPairGenerator;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class StorePurchasesTest {

    private static final Instant NOW = Instant.parse("2026-10-14T12:00:00Z");
    private static final Instant EXPIRES = NOW.plus(Duration.ofDays(7));
    private static final String MONTHLY = "presence.premium.monthly";
    private static final String YEARLY = "presence.premium.yearly";
    private static final String ANA = "ana@example.com";
    private static final String BEA = "bea@example.com";
    private static final String TOKEN = "abcdefghijklmnopqrstuvwxyz.ABCDEFGHIJ-0123456789_play";

    private final Clock clock = Clock.fixed(NOW, ZoneOffset.UTC);
    private final FakeApple apple = new FakeApple();
    private final MemoryStore store = new MemoryStore();

    // rbacr: how long each email holds premium (Instant.MAX: forever), and what was asked.
    private final Map<String, Instant> holds = new HashMap<>();
    private final List<String> rbacrCalls = new ArrayList<>();
    private int rbacrStatus = 200;

    // Google Play: each token's subscription, and the acknowledgements made.
    private final Map<String, String> subscriptions = new HashMap<>();
    private final List<String> acknowledged = new ArrayList<>();
    private int googleStatus = 200;

    private final Web web = (method, uri, headers, body) -> {
        var path = uri.getPath();
        if (uri.getHost().equals("rbacr.example.com")) {
            assertEquals("Bearer rbacr_grant", headers.get("authorization"));
            rbacrCalls.add(method + " " + path + " " + body);
            if (rbacrStatus != 200) {
                return new Web.Reply(rbacrStatus, "{}");
            }
            var answer = JsonReader.object(body);
            var email = JsonReader.string(answer, "email") != null ? JsonReader.string(answer, "email")
                    : JsonReader.string(answer, "grantee");
            if (path.equals("/api/check")) {
                var until = holds.get(email);
                return new Web.Reply(200, until == null ? "{\"allowed\":false,\"expiresAt\":null}"
                        : "{\"allowed\":true,\"expiresAt\":" + (until.equals(Instant.MAX) ? "null"
                        : "\"" + until + "\"") + "}");
            }
            if (method.equals("POST")) {
                holds.put(email, Instant.parse(JsonReader.string(answer, "endsAt")));
                return new Web.Reply(201, "{}");
            }
            holds.remove(email);
            return new Web.Reply(204, "");
        }
        if (uri.equals(GooglePlay.TOKEN_URI)) {
            assertTrue(body.startsWith("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion="));
            return new Web.Reply(200, "{\"access_token\":\"ya29.fake\",\"expires_in\":3599}");
        }
        assertEquals("Bearer ya29.fake", headers.get("authorization"));
        if (googleStatus != 200) {
            return new Web.Reply(googleStatus, "{}");
        }
        if (method.equals("POST") && path.endsWith(":acknowledge")) {
            acknowledged.add(path);
            return new Web.Reply(200, "{}");
        }
        var token = path.substring(path.lastIndexOf('/') + 1);
        var subscription = subscriptions.get(token);
        return subscription == null ? new Web.Reply(404, "{}") : new Web.Reply(200, subscription);
    };

    private final GooglePlay play = google(false);
    private StorePurchases purchases = purchases(true, false);

    private GooglePlay google(boolean allowTest) {
        try {
            var generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            return new GooglePlay("presence@example.iam.gserviceaccount.com",
                    generator.generateKeyPair().getPrivate(), web, clock, allowTest);
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private StorePurchases purchases(boolean configured, boolean allowSandbox) {
        return new StorePurchases(new AppleStore(apple.verifier(), allowSandbox), () -> play,
                new RbacrGrants(URI.create("https://rbacr.example.com"), configured ? "rbacr_grant" : null,
                        "presence", web), store, clock);
    }

    private static APIGatewayV2HTTPEvent event(String route, String email, String body) {
        var claims = email == null ? Map.<String, String>of() : Map.of("email", email, "email_verified", "true");
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(route);
        event.setBody(body);
        event.setRequestContext(APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build());
        return event;
    }

    private static String verifyBody(String platform, String productId, String data) {
        return "{\"platform\":\"" + platform + "\",\"productId\":\"" + productId + "\",\"verificationData\":\""
                + data + "\"}";
    }

    private String iosTransaction(String bundle, String product, Instant expires, String environment,
                                  String accountToken, boolean revoked) {
        return apple.sign(FakeApple.transaction(bundle, product, "2000000123", expires, environment, accountToken,
                revoked, NOW.minusSeconds(60)));
    }

    private com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse verify(String email, String body) {
        return purchases.handle(StorePurchases.VERIFY, event(StorePurchases.VERIFY, email, body));
    }

    private com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse iosVerify(String email,
                                                                                             String jws) {
        return verify(email, verifyBody("ios", MONTHLY, jws));
    }

    // --- App Store

    @Test
    void anAppStorePurchaseGrantsPremiumUntilItsEndAndALittleMore() {
        var reply = iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        assertEquals(200, reply.getStatusCode(), reply.getBody());
        var granted = EXPIRES.plus(StorePurchases.GRACE);
        assertEquals("{\"premium\":true,\"platform\":\"ios\",\"productId\":\"" + MONTHLY + "\",\"expiresAt\":"
                + EXPIRES.toEpochMilli() + ",\"grantedUntil\":" + granted.toEpochMilli() + "}", reply.getBody());
        assertEquals(granted, holds.get(ANA));
        assertEquals(ANA, store.bindings.get("purchase:ios:2000000123").email());
        assertEquals(granted, store.granted.get(ANA));
        assertTrue(rbacrCalls.get(1).startsWith("POST /api/systems/presence/grants {\"role\":\"premium\",\"grantee\":\""
                + ANA + "\",\"endsAt\":\"" + granted + "\"}"), rbacrCalls.toString());
    }

    @Test
    void verifyingAgainExtendsTheGrantWhenItRenewed() {
        iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        var renewed = EXPIRES.plus(Duration.ofDays(30));
        var reply = iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, renewed, "Production", null, false));
        assertEquals(200, reply.getStatusCode());
        assertEquals(renewed.plus(StorePurchases.GRACE), holds.get(ANA));
        // The same purchase again: the grant lasts already, rbacr is only asked.
        rbacrCalls.clear();
        iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, renewed, "Production", null, false));
        assertEquals(1, rbacrCalls.size(), rbacrCalls.toString());
    }

    @Test
    void aLongerGrantSomeoneElseMadeIsKept() {
        holds.put(ANA, Instant.MAX); // a voucher's, which never ends
        var reply = iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        assertEquals(200, reply.getStatusCode());
        assertTrue(reply.getBody().endsWith("\"grantedUntil\":null}"), reply.getBody());
        assertEquals(Instant.MAX, holds.get(ANA));
        assertEquals(1, rbacrCalls.size());
    }

    @Test
    void refusesWhatTheAppStoreDoesntVouchFor() {
        for (var jws : List.of(
                iosTransaction("com.example.other", MONTHLY, EXPIRES, "Production", null, false),
                iosTransaction(StorePurchase.APP_ID, "presence.other", EXPIRES, "Production", null, false),
                iosTransaction(StorePurchase.APP_ID, MONTHLY, NOW.minusSeconds(1), "Production", null, false),
                iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, true),
                iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Sandbox", null, false),
                iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Xcode", null, false),
                // Signed by a chain Apple's root didn't issue.
                new FakeApple().sign(FakeApple.transaction(StorePurchase.APP_ID, MONTHLY, "2000000123", EXPIRES,
                        "Production", null, false, NOW)))) {
            assertEquals(400, iosVerify(ANA, jws).getStatusCode());
        }
        // A yearly purchase sent as monthly.
        assertEquals(400, iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, YEARLY, EXPIRES, "Production", null,
                false)).getStatusCode());
        assertTrue(holds.isEmpty());
        assertTrue(store.bindings.isEmpty());
    }

    @Test
    void theSandboxCountsWhereAllowed() {
        purchases = purchases(true, true);
        var reply = iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Sandbox", null, false));
        assertEquals(200, reply.getStatusCode(), reply.getBody());
        assertEquals(EXPIRES.plus(StorePurchases.TEST_GRACE), holds.get(ANA));
    }

    @Test
    void aPurchaseBoundToAnotherAccountIs409() {
        var jws = iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false);
        assertEquals(200, iosVerify(ANA, jws).getStatusCode());
        var reply = iosVerify(BEA, jws);
        assertEquals(409, reply.getStatusCode());
        assertNull(holds.get(BEA));
        assertEquals(ANA, store.bindings.get("purchase:ios:2000000123").email());
    }

    @Test
    void aPurchaseMadeForAnotherAccountTokenIs409() {
        var anas = store.accountToken(ANA);
        var jws = iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", anas, false);
        assertEquals(409, iosVerify(BEA, jws).getStatusCode());
        assertEquals(200, iosVerify(ANA, jws).getStatusCode());
    }

    @Test
    void badRequests() {
        assertEquals(403, iosVerify(null, "x").getStatusCode());
        var unverified = event(StorePurchases.VERIFY, null, verifyBody("ios", MONTHLY, "x"));
        unverified.getRequestContext().getAuthorizer().getJwt()
                .setClaims(Map.of("email", ANA, "email_verified", "false"));
        assertEquals(403, purchases.handle(StorePurchases.VERIFY, unverified).getStatusCode());
        for (var body : List.of("", "{", "[]", "{\"platform\":\"ios\"}", verifyBody("web", MONTHLY, "x"),
                verifyBody("ios", "presence.other", "x"), verifyBody("ios", MONTHLY, ""),
                "{\"platform\":\"ios\",\"productId\":\"" + MONTHLY + "\",\"verificationData\":\""
                        + "x".repeat(StorePurchases.MAX_VERIFY) + "\"}")) {
            assertEquals(400, verify(ANA, body).getStatusCode(), body.length() > 80 ? "long" : body);
        }
    }

    @Test
    void notConfiguredIs503() {
        purchases = purchases(false, false);
        var reply = iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        assertEquals(503, reply.getStatusCode());
        assertEquals("{\"error\":\"store purchases not configured\"}", reply.getBody());
        var status = purchases.handle(StorePurchases.GET_STORE, event(StorePurchases.GET_STORE, ANA, null));
        assertEquals("{\"ios\":false,\"android\":false,\"accountToken\":null}", status.getBody());
        assertTrue(store.tokens.isEmpty());
    }

    @Test
    void androidIsOffWithoutAServiceAccount() {
        purchases = new StorePurchases(new AppleStore(apple.verifier(), false), null,
                new RbacrGrants(URI.create("https://rbacr.example.com"), "rbacr_grant", "presence", web), store,
                clock);
        assertEquals(503, verify(ANA, verifyBody("android", MONTHLY, TOKEN)).getStatusCode());
        var status = purchases.handle(StorePurchases.GET_STORE, event(StorePurchases.GET_STORE, ANA, null));
        assertTrue(status.getBody().startsWith("{\"ios\":true,\"android\":false,\"accountToken\":\""),
                status.getBody());
    }

    @Test
    void theAccountTokenStaysTheSame() {
        var first = purchases.handle(StorePurchases.GET_STORE, event(StorePurchases.GET_STORE, ANA, null)).getBody();
        var again = purchases.handle(StorePurchases.GET_STORE, event(StorePurchases.GET_STORE, ANA, null)).getBody();
        assertEquals(first, again);
        assertTrue(first.matches(".*\"accountToken\":\"[0-9a-f-]{36}\".*"), first);
    }

    @Test
    void rbacrFailingIs502() {
        rbacrStatus = 500;
        var reply = iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        assertEquals(502, reply.getStatusCode());
    }

    // --- Google Play

    private static String subscription(String state, String productId, Instant expires, boolean acknowledged,
                                       String extra) {
        return "{\"kind\":\"androidpublisher#subscriptionPurchaseV2\",\"subscriptionState\":\"" + state
                + "\",\"acknowledgementState\":\"ACKNOWLEDGEMENT_STATE_" + (acknowledged ? "ACKNOWLEDGED" : "PENDING")
                + "\",\"lineItems\":[{\"productId\":\"" + productId + "\",\"expiryTime\":\"" + expires + "\"}]"
                + extra + "}";
    }

    @Test
    void aGooglePlayPurchaseIsVerifiedAcknowledgedAndGranted() {
        subscriptions.put(TOKEN, subscription("SUBSCRIPTION_STATE_ACTIVE", MONTHLY, EXPIRES, false, ""));
        var reply = verify(ANA, verifyBody("android", MONTHLY, TOKEN));
        assertEquals(200, reply.getStatusCode(), reply.getBody());
        assertEquals(List.of("/androidpublisher/v3/applications/com.nu01.presence/purchases/subscriptions/"
                + MONTHLY + "/tokens/" + TOKEN + ":acknowledge"), acknowledged);
        assertEquals(EXPIRES.plus(StorePurchases.GRACE), holds.get(ANA));
        // Acknowledged once.
        subscriptions.put(TOKEN, subscription("SUBSCRIPTION_STATE_IN_GRACE_PERIOD", MONTHLY, EXPIRES, true, ""));
        assertEquals(200, verify(ANA, verifyBody("android", MONTHLY, TOKEN)).getStatusCode());
        assertEquals(1, acknowledged.size());
    }

    @Test
    void refusesWhatGooglePlayDoesntVouchFor() {
        var other = "zyxwvutsrqponmlkjihgfedcba.0987654321";
        subscriptions.put(TOKEN, subscription("SUBSCRIPTION_STATE_EXPIRED", MONTHLY, EXPIRES, true, ""));
        subscriptions.put(other, subscription("SUBSCRIPTION_STATE_ACTIVE", YEARLY, EXPIRES, true, ""));
        assertEquals(400, verify(ANA, verifyBody("android", MONTHLY, TOKEN)).getStatusCode());
        assertEquals(400, verify(ANA, verifyBody("android", MONTHLY, other)).getStatusCode());
        assertEquals(400, verify(ANA, verifyBody("android", MONTHLY, "unknown-token-0123456789")).getStatusCode());
        assertEquals(400, verify(ANA, verifyBody("android", MONTHLY, "has/slash/../0123456789")).getStatusCode());
        subscriptions.put(TOKEN, subscription("SUBSCRIPTION_STATE_ACTIVE", MONTHLY, EXPIRES, true,
                ",\"testPurchase\":{}"));
        assertEquals(400, verify(ANA, verifyBody("android", MONTHLY, TOKEN)).getStatusCode());
        assertTrue(holds.isEmpty());
        assertTrue(acknowledged.isEmpty());
    }

    @Test
    void googlePlayFailingIs502() {
        subscriptions.put(TOKEN, subscription("SUBSCRIPTION_STATE_ACTIVE", MONTHLY, EXPIRES, false, ""));
        googleStatus = 503;
        assertEquals(502, verify(ANA, verifyBody("android", MONTHLY, TOKEN)).getStatusCode());
        assertTrue(holds.isEmpty());
    }

    @Test
    void aReplacedGooglePurchaseOfAnotherAccountIs409() {
        subscriptions.put(TOKEN, subscription("SUBSCRIPTION_STATE_ACTIVE", MONTHLY, EXPIRES, true, ""));
        assertEquals(200, verify(ANA, verifyBody("android", MONTHLY, TOKEN)).getStatusCode());
        var upgraded = "upgraded-token-0123456789abcdef";
        subscriptions.put(upgraded, subscription("SUBSCRIPTION_STATE_ACTIVE", YEARLY, EXPIRES, true,
                ",\"linkedPurchaseToken\":\"" + TOKEN + "\""));
        assertEquals(409, verify(BEA, verifyBody("android", YEARLY, upgraded)).getStatusCode());
        assertEquals(200, verify(ANA, verifyBody("android", YEARLY, upgraded)).getStatusCode());
    }

    @Test
    void readsAServiceAccountKeyFile() throws Exception {
        var generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(2048);
        // As in Google's key files: the PEM in a JSON string, its lines joined by \n escapes.
        var pem = "-----BEGIN PRIVATE KEY-----\\n" + Base64.getEncoder()
                .encodeToString(generator.generateKeyPair().getPrivate().getEncoded()).replaceAll("(.{64})", "$1\\\\n")
                + "\\n-----END PRIVATE KEY-----\\n";
        var file = "{\"type\":\"service_account\",\"client_email\":\"p@example.iam.gserviceaccount.com\","
                + "\"private_key\":\"" + pem + "\"}";
        var google = GooglePlay.fromKeyFile(file, web, clock, false);
        assertEquals("ya29.fake", google.accessToken());
        assertThrows(IllegalArgumentException.class, () -> GooglePlay.fromKeyFile("{}", web, clock, false));
    }

    // --- App Store Server Notifications

    private String notification(String type, Instant expires, boolean revoked) {
        return notification(type, expires, revoked, NOW);
    }

    private String notification(String type, Instant expires, boolean revoked, Instant signed) {
        var transaction = iosTransaction(StorePurchase.APP_ID, MONTHLY, expires, "Production", null, revoked);
        var payload = "{\"notificationType\":\"" + type + "\",\"notificationUUID\":\"u\",\"data\":{\"bundleId\":\""
                + StorePurchase.APP_ID + "\",\"environment\":\"Production\",\"signedTransactionInfo\":\""
                + transaction + "\"},\"version\":\"2.0\",\"signedDate\":" + signed.toEpochMilli() + "}";
        return "{\"signedPayload\":\"" + apple.sign(payload) + "\"}";
    }

    private int notify(String body) {
        return purchases.handle(StorePurchases.APPLE_NOTIFICATIONS,
                event(StorePurchases.APPLE_NOTIFICATIONS, null, body)).getStatusCode();
    }

    @Test
    void aRenewalExtendsTheGrant() {
        iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        var renewed = EXPIRES.plus(Duration.ofDays(30));
        assertEquals(200, notify(notification("DID_RENEW", renewed, false)));
        assertEquals(renewed.plus(StorePurchases.GRACE), holds.get(ANA));
    }

    @Test
    void aRefundEndsTheGrantItMade() {
        iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        assertEquals(200, notify(notification("REFUND", EXPIRES, true)));
        assertNull(holds.get(ANA));
        assertNull(store.granted.get(ANA));
        assertTrue(store.bindings.get("purchase:ios:2000000123").revoked());
        assertTrue(rbacrCalls.getLast().startsWith("DELETE /api/systems/presence/grants"), rbacrCalls.toString());
    }

    @Test
    void anOlderSignedStateCantUndoARefund() {
        // The transaction the app sent at purchase, saved and sent again after the refund.
        var saved = iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false);
        assertEquals(200, iosVerify(ANA, saved).getStatusCode());
        assertEquals(200, notify(notification("REFUND", EXPIRES, true)));
        var replay = iosVerify(ANA, saved);
        assertEquals(400, replay.getStatusCode(), replay.getBody());
        assertNull(holds.get(ANA));
        // Nor an older notification, replayed.
        assertEquals(200, notify(notification("DID_RENEW", EXPIRES.plus(Duration.ofDays(30)), false,
                NOW.minusSeconds(30))));
        assertNull(holds.get(ANA));
        assertTrue(store.bindings.get("purchase:ios:2000000123").revoked());
    }

    @Test
    void anExpiryLeavesSomeoneElsesGrantAlone() {
        iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        holds.put(ANA, Instant.MAX); // a root gave premium since
        assertEquals(200, notify(notification("EXPIRED", NOW.minusSeconds(1), false)));
        assertEquals(Instant.MAX, holds.get(ANA));
        assertFalse(rbacrCalls.getLast().startsWith("DELETE"));
    }

    @Test
    void notificationsOfUnboundPurchasesChangeNothing() {
        assertEquals(200, notify(notification("SUBSCRIBED", EXPIRES, false)));
        assertTrue(holds.isEmpty());
        assertTrue(store.bindings.isEmpty());
    }

    @Test
    void forgedNotificationsAre400() {
        iosVerify(ANA, iosTransaction(StorePurchase.APP_ID, MONTHLY, EXPIRES, "Production", null, false));
        var forger = new FakeApple();
        var forged = "{\"signedPayload\":\"" + forger.sign("{\"notificationType\":\"REFUND\",\"data\":{}}") + "\"}";
        assertEquals(400, notify(forged));
        assertEquals(400, notify("{}"));
        assertEquals(400, notify("not json"));
        assertEquals(400, notify("x".repeat(StorePurchases.MAX_NOTIFICATION + 1)));
        assertEquals(EXPIRES.plus(StorePurchases.GRACE), holds.get(ANA));
    }

    @Test
    void otherRoutesArentItsOwn() {
        assertNull(purchases.handle("GET /api/payments/links", event("GET /api/payments/links", ANA, null)));
    }

    /** The payments table, in memory. */
    static final class MemoryStore implements PurchaseStore {
        final Map<String, String> tokens = new HashMap<>();
        final Map<String, Binding> bindings = new HashMap<>();
        final Map<String, Set<String>> accounts = new HashMap<>();
        final Map<String, Instant> granted = new HashMap<>();

        @Override
        public String accountToken(String email) {
            return tokens.computeIfAbsent(email, e -> java.util.UUID.randomUUID().toString());
        }

        @Override
        public Bound bind(String email, String key, String productId, Instant expiresAt, boolean revoked,
                          Instant signedAt, Instant now) {
            var existing = bindings.get(key);
            if (existing != null && !existing.email().equals(email)) {
                return new Bound(existing.email(), false);
            }
            if (existing != null && existing.signedAt().isAfter(signedAt)) {
                return new Bound(email, true);
            }
            bindings.put(key, new Binding(key, email, productId, expiresAt, revoked, signedAt));
            accounts.computeIfAbsent(email, e -> new LinkedHashSet<>()).add(key);
            return new Bound(email, false);
        }

        @Override
        public Optional<Binding> binding(String key) {
            return Optional.ofNullable(bindings.get(key));
        }

        @Override
        public List<Binding> purchasesOf(String email) {
            return accounts.getOrDefault(email, Set.of()).stream().map(bindings::get).toList();
        }

        @Override
        public Instant grantedUntil(String email) {
            return granted.get(email);
        }

        @Override
        public void grantedUntil(String email, Instant until) {
            if (until == null) {
                granted.remove(email);
            } else {
                granted.put(email, until);
            }
        }
    }
}
