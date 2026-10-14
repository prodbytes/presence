package presence.payments;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AppleJwsTest {

    private static final Instant SIGNED = Instant.parse("2026-10-14T12:00:00Z");
    private static final String PAYLOAD = FakeApple.transaction(StorePurchase.APP_ID, "presence.premium.monthly",
            "2000000123", SIGNED.plusSeconds(3600), "Production", null, false, SIGNED);

    private final FakeApple apple = new FakeApple();

    @Test
    void theBundledRootIsAppleRootCaG3() throws Exception {
        assertNotNull(AppleJws.apple());
    }

    @Test
    void verifiesAChainToTheTrustedRoot() throws Exception {
        var payload = apple.verifier().verify(apple.sign(PAYLOAD));
        assertEquals("2000000123", payload.get("originalTransactionId"));
    }

    @Test
    void refusesAnotherRoot() {
        var other = new FakeApple();
        var refused = assertThrows(AppleJws.InvalidJws.class, () -> other.verifier().verify(apple.sign(PAYLOAD)));
        assertTrue(refused.getMessage().contains("root"), refused.getMessage());
    }

    @Test
    void refusesAChainThatOnlyNamesTheTrustedRoot() {
        // The trusted root's certificate in x5c, but an intermediate it never signed.
        var attacker = new FakeApple();
        var refused = assertThrows(AppleJws.InvalidJws.class,
                () -> apple.verifier().verify(attacker.sign(PAYLOAD, apple.root)));
        assertTrue(refused.getMessage().contains("validate"), refused.getMessage());
    }

    @Test
    void refusesChainsWithoutApplesOids() {
        var noIntermediateOid = new FakeApple(false, true, Instant.parse("2020-01-01T00:00:00Z"),
                Instant.parse("2040-01-01T00:00:00Z"));
        assertThrows(AppleJws.InvalidJws.class,
                () -> noIntermediateOid.verifier().verify(noIntermediateOid.sign(PAYLOAD)));
        var noLeafOid = new FakeApple(true, false, Instant.parse("2020-01-01T00:00:00Z"),
                Instant.parse("2040-01-01T00:00:00Z"));
        assertThrows(AppleJws.InvalidJws.class, () -> noLeafOid.verifier().verify(noLeafOid.sign(PAYLOAD)));
    }

    @Test
    void refusesACertificateExpiredWhenSigned() {
        var expired = new FakeApple(true, true, Instant.parse("2020-01-01T00:00:00Z"),
                Instant.parse("2025-01-01T00:00:00Z"));
        assertThrows(AppleJws.InvalidJws.class, () -> expired.verifier().verify(expired.sign(PAYLOAD)));
    }

    @Test
    void refusesATamperedPayload() {
        var jws = apple.sign(PAYLOAD);
        var parts = jws.split("\\.");
        var forged = Base64.getUrlEncoder().withoutPadding().encodeToString(
                PAYLOAD.replace("2000000123", "2000000999").getBytes(StandardCharsets.UTF_8));
        var refused = assertThrows(AppleJws.InvalidJws.class,
                () -> apple.verifier().verify(parts[0] + "." + forged + "." + parts[2]));
        assertTrue(refused.getMessage().contains("signature"), refused.getMessage());
    }

    @Test
    void refusesWhatIsntACompactEs256Jws() {
        var verifier = apple.verifier();
        var url = Base64.getUrlEncoder().withoutPadding();
        var jws = apple.sign(PAYLOAD);
        var parts = jws.split("\\.");
        var none = url.encodeToString("{\"alg\":\"none\"}".getBytes(StandardCharsets.UTF_8));
        var noChain = url.encodeToString("{\"alg\":\"ES256\",\"x5c\":[]}".getBytes(StandardCharsets.UTF_8));
        for (var bad : new String[]{null, "", "a.b", "a.b.c.d", "!!.??.**", none + "." + parts[1] + "." + parts[2],
                noChain + "." + parts[1] + "." + parts[2], "x".repeat(AppleJws.MAX_LENGTH + 1)}) {
            assertThrows(AppleJws.InvalidJws.class, () -> verifier.verify(bad), String.valueOf(bad));
        }
    }
}
