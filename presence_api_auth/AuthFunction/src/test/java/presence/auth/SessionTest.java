package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Presence sessions: the exchange, the token, refresh tokens, Apple's revocation. */
class SessionTest {

    private static final Instant NOW = Instant.parse("2026-10-14T12:00:00Z");
    private static final String ISSUER = "https://presence.nu01.com/api/auth";
    private static final String WEB_CLIENT = "123-web.apps.googleusercontent.com";
    private static final String BUNDLE = "com.nu01.presence";

    private static final KeyPair GOOGLE_KEY = rsa();
    private static final KeyPair APPLE_KEY = rsa();
    private static final KeyPair PRESENCE_KEY = rsa();

    /** A clock tests can move. */
    private static final class MovableClock extends Clock {
        Instant now = NOW;

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return now;
        }
    }

    private final MovableClock clock = new MovableClock();
    private final MemorySessions store = new MemorySessions();
    private final List<URI> fetched = new ArrayList<>();
    private final List<String> applePosts = new ArrayList<>();
    private int appleStatus = 200;

    private final SessionSigner signer = new SessionSigner() {
        @Override
        public RSAPublicKey publicKey() {
            return (RSAPublicKey) PRESENCE_KEY.getPublic();
        }

        @Override
        public byte[] sign(byte[] input) {
            try {
                var s = Signature.getInstance("SHA256withRSA");
                s.initSign(PRESENCE_KEY.getPrivate());
                s.update(input);
                return s.sign();
            } catch (Exception e) {
                throw new IllegalStateException(e);
            }
        }
    };

    private Jwks jwks(KeyPair key, String kid) {
        return new Jwks(URI.create("https://keys.example/" + kid), uri -> {
            fetched.add(uri);
            return new Jwks.Reply(200, "public, max-age=600", jwksJson(key, kid));
        }, clock);
    }

    private final ProviderTokens providers = new ProviderTokens(jwks(GOOGLE_KEY, "g1"), java.util.Set.of(WEB_CLIENT),
            jwks(APPLE_KEY, "a1"), java.util.Set.of(BUNDLE), clock);
    private final Sessions sessions = new Sessions(store, new SecureRandom(), clock);
    private final SessionTokens tokens = new SessionTokens(signer, ISSUER, clock);

    /** Apple's key for the client secret, and a sealer that only marks what it sealed. */
    private static final KeyPair APPLE_SIGNIN_KEY = ec();
    private final AppleAccounts apple = new AppleAccounts(
            new AppleAccounts.Key("TEAM123456", "KEY1234567", APPLE_SIGNIN_KEY::getPrivate), store,
            new AppleAccounts.Sealer() {
                @Override
                public String seal(String plain, String subject) {
                    return "sealed(" + subject + "):" + plain;
                }

                @Override
                public String open(String sealed, String subject) {
                    var prefix = "sealed(" + subject + "):";
                    assertTrue(sealed.startsWith(prefix), "opened for another identity");
                    return sealed.substring(prefix.length());
                }
            },
            (uri, form) -> {
                applePosts.add(uri + " " + form);
                if (appleStatus != 200) {
                    return new AppleAccounts.Reply(appleStatus, "{\"error\":\"invalid_grant\"}");
                }
                return new AppleAccounts.Reply(200, uri.equals(AppleAccounts.TOKEN)
                        ? "{\"access_token\":\"at\",\"refresh_token\":\"apple-refresh\",\"id_token\":\"x\"}" : "");
            }, clock);

    private final SessionHandler handler = new SessionHandler(providers, tokens, sessions, store, apple, clock);

    // --- the exchange ---

    @Test
    void aGoogleSignInBecomesAPresenceSession() throws Exception {
        var answer = exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}");
        assertEquals(200, answer.getStatusCode(), answer.getBody());
        var body = Jwt.object(answer.getBody().getBytes(StandardCharsets.UTF_8));
        assertEquals(NOW.plus(Duration.ofHours(1)).getEpochSecond(), ((Number) body.get("expiresAt")).longValue());
        assertTrue(Sessions.REFRESH_TOKEN.matcher((String) body.get("refreshToken")).matches());
        assertEquals("no-store", answer.getHeaders().get("Cache-Control"));

        var claims = verifiedByJwks((String) body.get("token"));
        assertEquals(ISSUER, claims.get("iss"));
        assertEquals("presence", claims.get("aud"));
        assertEquals(SessionTokens.subjectOf(ProviderTokens.GOOGLE, "111"), claims.get("sub"));
        assertTrue(((String) claims.get("sub")).matches("p_[0-9a-f]{32}"));
        assertEquals("ana@nu01.com", claims.get("email"));
        assertEquals(true, claims.get("email_verified"));
        assertEquals("Ana", claims.get("name"));
        assertEquals("https://example.com/ana.png", claims.get("picture"));
        assertEquals("nu01.com", claims.get("hd"));
        assertEquals(ProviderTokens.GOOGLE, claims.get("idp"));
        assertEquals("111", claims.get("idp_sub"));
        assertEquals(NOW.getEpochSecond() + 3600, ((Number) claims.get("exp")).longValue());
    }

    @Test
    void theSessionsIdentityIsTheProvidersSoProfilesKeepTheirLinks() throws Exception {
        var token = (String) Jwt.object(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}")
                .getBody().getBytes(StandardCharsets.UTF_8)).get("token");
        // As the JWT authorizer passes them: strings.
        var claims = new HashMap<String, String>();
        Jwt.parse(token).claims().forEach((k, v) -> claims.put(k, String.valueOf(v)));
        var caller = Caller.of(claims);
        assertEquals("https://accounts.google.com#111", caller.subject());
        assertEquals("ana@nu01.com", caller.verifiedEmail());
        // The session's own iss and sub never name a profile's subject.
        var bare = new HashMap<>(claims);
        bare.remove("idp");
        bare.remove("idp_sub");
        assertFalse(Caller.of(bare).hasSubject());
    }

    @Test
    void googlesOtherIssuerSpellingIsTheSameIdentity() throws Exception {
        var claims = verifiedByJwks(tokenOf(exchange("{\"provider\":\"google\",\"idToken\":"
                + q(google(Map.of("iss", "accounts.google.com"))) + "}")));
        assertEquals(ProviderTokens.GOOGLE, claims.get("idp"));
    }

    @Test
    void tokensThatArentGoodAreRefused() throws Exception {
        for (var bad : List.of(
                google(Map.of("aud", "someone-else")),
                google(Map.of("exp", NOW.minusSeconds(120).getEpochSecond())),
                google(Map.of("iat", NOW.plusSeconds(600).getEpochSecond())),
                google(Map.of("iss", "https://evil.example")),
                google(Map.of("sub", "")),
                signed(APPLE_KEY, "g1", "RS256", googleClaims(Map.of())),  // wrong key
                signed(GOOGLE_KEY, "unknown", "RS256", googleClaims(Map.of())),
                unsigned(googleClaims(Map.of())),
                "not.a.jwt",
                "x")) {
            var answer = exchange("{\"provider\":\"google\",\"idToken\":" + q(bad) + "}");
            assertEquals(401, answer.getStatusCode(), bad);
        }
        // An Apple token isn't Google's, nor the other way round.
        assertEquals(401, exchange("{\"provider\":\"google\",\"idToken\":" + q(apple(Map.of())) + "}").getStatusCode());
        assertEquals(401, exchange("{\"provider\":\"apple\",\"idToken\":" + q(google(Map.of()))
                + ",\"nonce\":\"n\"}").getStatusCode());
        assertTrue(store.families.isEmpty());
    }

    @Test
    void anUnverifiedEmailIsForbidden() throws Exception {
        assertEquals(403, exchange("{\"provider\":\"google\",\"idToken\":"
                + q(google(Map.of("email_verified", false))) + "}").getStatusCode());
        assertEquals(403, exchange("{\"provider\":\"google\",\"idToken\":"
                + q(google(Map.of("email", "not-an-email"))) + "}").getStatusCode());
    }

    @Test
    void malformedRequestsAndProvidersWithoutClients() throws Exception {
        assertEquals(400, exchange("not json").getStatusCode());
        assertEquals(400, exchange("{\"provider\":\"github\",\"idToken\":\"x\"}").getStatusCode());
        assertEquals(400, exchange("{\"provider\":\"google\"}").getStatusCode());
        var noApple = new SessionHandler(new ProviderTokens(jwks(GOOGLE_KEY, "g1"), java.util.Set.of(WEB_CLIENT),
                jwks(APPLE_KEY, "a1"), java.util.Set.of(), clock), tokens, sessions, store, apple, clock);
        assertEquals(503, noApple.handleRequest(event(SessionHandler.EXCHANGE,
                "{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of())) + ",\"nonce\":\"raw-nonce\"}"), null)
                .getStatusCode());
        assertEquals(404, handler.handleRequest(event("GET /api/auth/session", null), null).getStatusCode());
    }

    @Test
    void theStreamerAsksForNoRefreshToken() throws Exception {
        var answer = exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + ",\"refresh\":false}");
        assertEquals(200, answer.getStatusCode());
        assertFalse(answer.getBody().contains("refreshToken"));
        assertTrue(store.families.isEmpty());
    }

    // --- Apple ---

    @Test
    void anAppleSignInChecksTheNonceAndKeepsTheFirstName() throws Exception {
        var first = exchange("{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of()))
                + ",\"nonce\":\"raw-nonce\",\"name\":\"  Ana\\u0000  Lima \"}");
        assertEquals(200, first.getStatusCode(), first.getBody());
        var claims = verifiedByJwks(tokenOf(first));
        assertEquals(ProviderTokens.APPLE, claims.get("idp"));
        assertEquals("001234.abcd", claims.get("idp_sub"));
        assertEquals("x7@privaterelay.appleid.com", claims.get("email"));
        assertEquals("Ana Lima", claims.get("name"));

        // Later sign-ins (another device): Apple sends no name, Presence has it.
        var later = exchange("{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of()))
                + ",\"nonce\":\"raw-nonce\"}");
        assertEquals("Ana Lima", verifiedByJwks(tokenOf(later)).get("name"));
        // And so do its refreshes.
        var refreshed = handler.handleRequest(event(SessionHandler.REFRESH,
                "{\"refreshToken\":" + q(refreshOf(later)) + "}"), null);
        assertEquals("Ana Lima", verifiedByJwks(tokenOf(refreshed)).get("name"));
    }

    @Test
    void anAppleTokenWithoutTheRightNonceIsRefused() throws Exception {
        assertEquals(401, exchange("{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of()))
                + ",\"nonce\":\"another\"}").getStatusCode());
        assertEquals(401, exchange("{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of())) + "}").getStatusCode());
        var noNonce = new LinkedHashMap<>(appleClaims(Map.of()));
        noNonce.remove("nonce");
        assertEquals(401, exchange("{\"provider\":\"apple\",\"idToken\":"
                + q(signed(APPLE_KEY, "a1", "RS256", noNonce)) + ",\"nonce\":\"raw-nonce\"}").getStatusCode());
    }

    @Test
    void anAuthorizationCodeKeepsApplesRefreshTokenSealedAndAccountDeletionRevokesIt() throws Exception {
        var answer = exchange("{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of()))
                + ",\"nonce\":\"raw-nonce\",\"authorizationCode\":\"c0de\"}");
        assertEquals(200, answer.getStatusCode());
        var subject = ProviderTokens.APPLE + "#001234.abcd";
        var kept = store.identities.get(subject);
        assertEquals(BUNDLE, kept.appleClientId());
        assertEquals("sealed(" + subject + "):apple-refresh", kept.appleRefreshToken());
        assertEquals(1, applePosts.size());
        var post = applePosts.getFirst();
        assertTrue(post.startsWith(AppleAccounts.TOKEN + " "), post);
        var form = form(post.substring(post.indexOf(' ') + 1));
        assertEquals(BUNDLE, form.get("client_id"));
        assertEquals("c0de", form.get("code"));
        assertEquals("authorization_code", form.get("grant_type"));
        assertClientSecret(form.get("client_secret"));

        // The account is deleted: its sessions end, Apple is told, nothing is kept.
        var refresh = refreshOf(answer);
        assertTrue(new AccountSessions(sessions, store, apple).end(subject));
        var revoke = form(applePosts.getLast().substring(applePosts.getLast().indexOf(' ') + 1));
        assertTrue(applePosts.getLast().startsWith(AppleAccounts.REVOKE + " "));
        assertEquals("apple-refresh", revoke.get("token"));
        assertEquals("refresh_token", revoke.get("token_type_hint"));
        assertClientSecret(revoke.get("client_secret"));
        assertNull(store.identities.get(subject));
        assertEquals(401, refresh(refresh).getStatusCode());
    }

    @Test
    void appleRefusingTheRevocationKeepsItsTokenToTryAgain() throws Exception {
        exchange("{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of()))
                + ",\"nonce\":\"raw-nonce\",\"authorizationCode\":\"c0de\"}");
        var subject = ProviderTokens.APPLE + "#001234.abcd";
        appleStatus = 400;
        assertFalse(new AccountSessions(sessions, store, apple).end(subject));
        assertEquals("sealed(" + subject + "):apple-refresh", store.identities.get(subject).appleRefreshToken());
        appleStatus = 200;
        assertTrue(new AccountSessions(sessions, store, apple).end(subject));
        assertNull(store.identities.get(subject));
    }

    @Test
    void withoutApplesKeyNoCodeIsTraded() throws Exception {
        var unconfigured = new AppleAccounts(null, store, null, null, clock);
        var noKey = new SessionHandler(providers, tokens, sessions, store, unconfigured, clock);
        assertEquals(200, noKey.handleRequest(event(SessionHandler.EXCHANGE, "{\"provider\":\"apple\",\"idToken\":"
                + q(apple(Map.of())) + ",\"nonce\":\"raw-nonce\",\"authorizationCode\":\"c0de\"}"), null)
                .getStatusCode());
        assertTrue(applePosts.isEmpty());
        // Nothing kept, nothing to revoke.
        assertTrue(unconfigured.revoke(ProviderTokens.APPLE + "#001234.abcd"));
    }

    @Test
    void anAppleTokenEndpointFailureDoesntFailTheSignIn() throws Exception {
        appleStatus = 400;
        var answer = exchange("{\"provider\":\"apple\",\"idToken\":" + q(apple(Map.of()))
                + ",\"nonce\":\"raw-nonce\",\"authorizationCode\":\"c0de\"}");
        assertEquals(200, answer.getStatusCode());
        assertNull(store.identities.get(ProviderTokens.APPLE + "#001234.abcd"));
    }

    // --- refresh tokens ---

    @Test
    void aRefreshRotatesTheTokenAndSlidesTheExpiry() throws Exception {
        var first = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        clock.now = NOW.plus(Duration.ofDays(59));
        var second = refresh(first);
        assertEquals(200, second.getStatusCode(), second.getBody());
        var next = refreshOf(second);
        assertNotEquals(first, next);
        var claims = verifiedByJwks(tokenOf(second));
        assertEquals("111", claims.get("idp_sub"));
        assertEquals(clock.now.getEpochSecond() + 3600, ((Number) claims.get("exp")).longValue());
        // 59 more days: still good (the expiry slid), and rotated again.
        clock.now = clock.now.plus(Duration.ofDays(59));
        assertEquals(200, refresh(next).getStatusCode());
    }

    @Test
    void aRetryWithinAMinuteGetsAnotherTokenNotTheEndOfTheSession() throws Exception {
        var first = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        var lost = refreshOf(refresh(first));
        // The answer was lost: the app retries with the same token.
        clock.now = clock.now.plusSeconds(30);
        var retried = refresh(first);
        assertEquals(200, retried.getStatusCode(), retried.getBody());
        var next = refreshOf(retried);
        assertNotEquals(lost, next);
        assertEquals(200, refresh(next).getStatusCode());
        // The grace runs from the first use: past it, the same token is reuse.
        clock.now = clock.now.plusSeconds(31);
        assertEquals(401, refresh(first).getStatusCode());
        // ...which ends the session: its newer tokens too.
        assertEquals(401, refresh(lost).getStatusCode());
    }

    @Test
    void aReusedRefreshTokenEndsTheWholeSession() throws Exception {
        var first = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        var next = refreshOf(refresh(first));
        clock.now = clock.now.plus(Sessions.GRACE).plusSeconds(1);
        // Someone kept the first one and uses it: refused, and the session ends.
        assertEquals(401, refresh(first).getStatusCode());
        assertEquals(401, refresh(next).getStatusCode());
        // Another sign-in is another session.
        var other = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        assertEquals(200, refresh(other).getStatusCode());
    }

    @Test
    void anUnusedRefreshTokenExpiresAfterSixtyDays() throws Exception {
        var first = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        clock.now = NOW.plus(Sessions.REFRESH_FOR).plusSeconds(1);
        assertEquals(401, refresh(first).getStatusCode());
        assertEquals(401, refresh("prt_" + "A".repeat(43)).getStatusCode());
        assertEquals(401, refresh("not-a-token").getStatusCode());
        assertEquals(400, handler.handleRequest(event(SessionHandler.REFRESH, ""), null).getStatusCode());
    }

    @Test
    void signingOutRevokesTheSession() throws Exception {
        var first = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        var revoked = handler.handleRequest(event(SessionHandler.REVOKE, "{\"refreshToken\":" + q(first) + "}"), null);
        assertEquals(204, revoked.getStatusCode());
        assertEquals(401, refresh(first).getStatusCode());
        // Unknown tokens are no different, so the route tells nothing.
        assertEquals(204, handler.handleRequest(event(SessionHandler.REVOKE,
                "{\"refreshToken\":\"prt_" + "B".repeat(43) + "\"}"), null).getStatusCode());
    }

    @Test
    void accountDeletionEndsEverySessionOfTheIdentityOnly() throws Exception {
        var phone = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        var laptop = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":" + q(google(Map.of())) + "}"));
        var bob = refreshOf(exchange("{\"provider\":\"google\",\"idToken\":"
                + q(google(Map.of("sub", "222", "email", "bob@example.com"))) + "}"));
        assertTrue(new AccountSessions(sessions, store, apple).end(ProviderTokens.GOOGLE + "#111"));
        assertEquals(401, refresh(phone).getStatusCode());
        assertEquals(401, refresh(laptop).getStatusCode());
        assertEquals(200, refresh(bob).getStatusCode());
    }

    // --- the issuer's documents ---

    @Test
    void theIssuerPublishesItsConfigurationAndKey() throws Exception {
        var discovery = handler.handleRequest(event(SessionHandler.DISCOVERY, null), null);
        assertEquals(200, discovery.getStatusCode());
        assertEquals("public, max-age=3600", discovery.getHeaders().get("Cache-Control"));
        var document = Jwt.object(discovery.getBody().getBytes(StandardCharsets.UTF_8));
        assertEquals(ISSUER, document.get("issuer"));
        assertEquals(ISSUER + "/.well-known/jwks.json", document.get("jwks_uri"));
        var jwks = handler.handleRequest(event(SessionHandler.JWKS, null), null);
        var keys = Jwks.parse(jwks.getBody());
        assertEquals(1, keys.size());
        assertEquals(PRESENCE_KEY.getPublic(), keys.get(signer.kid()));
        assertTrue(signer.kid().matches("[A-Za-z0-9_-]{43}"));
    }

    // --- keys ---

    @Test
    void providerKeysAreCachedAndAnUnknownKidRefetchesAtMostOnceAMinute() {
        var keys = jwks(GOOGLE_KEY, "g1");
        assertTrue(keys.key("g1").isPresent());
        assertTrue(keys.key("g1").isPresent());
        assertEquals(1, fetched.size());
        assertTrue(keys.key("forged").isEmpty());
        assertTrue(keys.key("forged-again").isEmpty());
        assertEquals(1, fetched.size());
        clock.now = clock.now.plusSeconds(61);
        assertTrue(keys.key("forged").isEmpty());
        assertEquals(2, fetched.size());
        assertEquals(Duration.ofSeconds(600), Jwks.cacheFor("public, max-age=600, must-revalidate"));
        assertEquals(Jwks.AT_MOST, Jwks.cacheFor("max-age=999999"));
        assertEquals(Jwks.DEFAULT_FOR, Jwks.cacheFor(null));
    }

    @Test
    void namesAreCleanedAndCut() {
        assertEquals("Ana Lima", SessionHandler.name(" Ana \n\t Lima "));
        assertNull(SessionHandler.name("  "));
        assertNull(SessionHandler.name(42));
        assertEquals(SessionHandler.MAX_NAME, SessionHandler.name("a".repeat(500)).length());
    }

    // --- helpers ---

    private APIGatewayV2HTTPResponse exchange(String body) {
        return handler.handleRequest(event(SessionHandler.EXCHANGE, body), null);
    }

    private APIGatewayV2HTTPResponse refresh(String refreshToken) {
        return handler.handleRequest(event(SessionHandler.REFRESH, "{\"refreshToken\":" + q(refreshToken) + "}"), null);
    }

    private static APIGatewayV2HTTPEvent event(String route, String body) {
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(route);
        event.setBody(body);
        event.setHeaders(Map.of());
        return event;
    }

    private static String tokenOf(APIGatewayV2HTTPResponse answer) {
        assertEquals(200, answer.getStatusCode(), answer.getBody());
        return (String) Jwt.object(answer.getBody().getBytes(StandardCharsets.UTF_8)).get("token");
    }

    private static String refreshOf(APIGatewayV2HTTPResponse answer) {
        assertEquals(200, answer.getStatusCode(), answer.getBody());
        return (String) Jwt.object(answer.getBody().getBytes(StandardCharsets.UTF_8)).get("refreshToken");
    }

    /** The token's claims, after checking it as an authorizer would, with the published JWKS. */
    private Map<String, Object> verifiedByJwks(String token) throws Exception {
        var published = Jwks.parse(handler.handleRequest(event(SessionHandler.JWKS, null), null).getBody());
        var jwt = Jwt.parse(token);
        assertEquals("RS256", jwt.header().get("alg"));
        var verifier = Signature.getInstance("SHA256withRSA");
        verifier.initVerify(published.get((String) jwt.header().get("kid")));
        verifier.update(jwt.signingInput());
        assertTrue(verifier.verify(jwt.signature()), "the session token's signature");
        return jwt.claims();
    }

    private void assertClientSecret(String secret) throws Exception {
        var jwt = Jwt.parse(secret);
        assertEquals("ES256", jwt.header().get("alg"));
        assertEquals("KEY1234567", jwt.header().get("kid"));
        assertEquals("TEAM123456", jwt.claims().get("iss"));
        assertEquals(BUNDLE, jwt.claims().get("sub"));
        assertEquals("https://appleid.apple.com", jwt.claims().get("aud"));
        var verifier = Signature.getInstance("SHA256withECDSAinP1363Format");
        verifier.initVerify(APPLE_SIGNIN_KEY.getPublic());
        verifier.update(jwt.signingInput());
        assertTrue(verifier.verify(jwt.signature()), "the client secret's signature");
    }

    private static Map<String, String> form(String form) {
        var fields = new HashMap<String, String>();
        for (var pair : form.split("&")) {
            var at = pair.indexOf('=');
            fields.put(java.net.URLDecoder.decode(pair.substring(0, at), StandardCharsets.UTF_8),
                    java.net.URLDecoder.decode(pair.substring(at + 1), StandardCharsets.UTF_8));
        }
        return fields;
    }

    private static Map<String, Object> googleClaims(Map<String, Object> overrides) {
        var claims = new LinkedHashMap<String, Object>();
        claims.put("iss", "https://accounts.google.com");
        claims.put("aud", WEB_CLIENT);
        claims.put("azp", WEB_CLIENT);
        claims.put("sub", "111");
        claims.put("email", "ana@nu01.com");
        claims.put("email_verified", true);
        claims.put("name", "Ana");
        claims.put("picture", "https://example.com/ana.png");
        claims.put("hd", "nu01.com");
        claims.put("iat", NOW.minusSeconds(10).getEpochSecond());
        claims.put("exp", NOW.plusSeconds(3590).getEpochSecond());
        claims.putAll(overrides);
        return claims;
    }

    private static Map<String, Object> appleClaims(Map<String, Object> overrides) {
        var claims = new LinkedHashMap<String, Object>();
        claims.put("iss", "https://appleid.apple.com");
        claims.put("aud", BUNDLE);
        claims.put("sub", "001234.abcd");
        claims.put("email", "x7@privaterelay.appleid.com");
        // Apple sends these as strings.
        claims.put("email_verified", "true");
        claims.put("is_private_email", "true");
        claims.put("nonce", ProviderTokens.sha256Hex("raw-nonce"));
        claims.put("iat", NOW.minusSeconds(10).getEpochSecond());
        claims.put("exp", NOW.plusSeconds(590).getEpochSecond());
        claims.putAll(overrides);
        return claims;
    }

    private static String google(Map<String, Object> overrides) throws Exception {
        return signed(GOOGLE_KEY, "g1", "RS256", googleClaims(overrides));
    }

    private static String apple(Map<String, Object> overrides) throws Exception {
        return signed(APPLE_KEY, "a1", "RS256", appleClaims(overrides));
    }

    private static String signed(KeyPair key, String kid, String alg, Map<String, Object> claims) throws Exception {
        var input = Jwt.base64(Jwt.json(Map.of("alg", alg, "kid", kid)).getBytes(StandardCharsets.UTF_8)) + "."
                + Jwt.base64(Jwt.json(claims).getBytes(StandardCharsets.UTF_8));
        var s = Signature.getInstance("SHA256withRSA");
        s.initSign(key.getPrivate());
        s.update(input.getBytes(StandardCharsets.US_ASCII));
        return input + "." + Jwt.base64(s.sign());
    }

    private static String unsigned(Map<String, Object> claims) {
        return Jwt.base64(Jwt.json(Map.of("alg", "none", "kid", "g1")).getBytes(StandardCharsets.UTF_8)) + "."
                + Jwt.base64(Jwt.json(claims).getBytes(StandardCharsets.UTF_8)) + ".c2ln";
    }

    private static String jwksJson(KeyPair key, String kid) {
        var pub = (RSAPublicKey) key.getPublic();
        var encoder = Base64.getUrlEncoder().withoutPadding();
        return "{\"keys\":[{\"kty\":\"RSA\",\"kid\":\"" + kid + "\",\"use\":\"sig\",\"alg\":\"RS256\",\"n\":\""
                + encoder.encodeToString(pub.getModulus().toByteArray()) + "\",\"e\":\""
                + encoder.encodeToString(pub.getPublicExponent().toByteArray()) + "\"}]}";
    }

    private static String q(String s) {
        return Json.string(s);
    }

    private static KeyPair rsa() {
        try {
            var generator = KeyPairGenerator.getInstance("RSA");
            generator.initialize(2048);
            return generator.generateKeyPair();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static KeyPair ec() {
        try {
            var generator = KeyPairGenerator.getInstance("EC");
            generator.initialize(new ECGenParameterSpec("secp256r1"));
            return generator.generateKeyPair();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
