package presence.payments;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class OriginCheckTest {

    static APIGatewayV2HTTPEvent event(Map<String, String> headers) {
        var event = new APIGatewayV2HTTPEvent();
        event.setHeaders(headers);
        return event;
    }

    @Test
    void withASecretOnlyItsHeaderPasses() {
        var check = new OriginCheck("s3cret-value");
        assertTrue(check.allows(event(Map.of("x-presence-origin-verify", "s3cret-value"))));
        assertTrue(check.allows(event(Map.of("X-Presence-Origin-Verify", "s3cret-value"))), "any case");
        assertFalse(check.allows(event(Map.of("x-presence-origin-verify", "s3cret-valuX"))));
        assertFalse(check.allows(event(Map.of("x-presence-origin-verify", ""))));
        assertFalse(check.allows(event(Map.of("authorization", "Bearer s3cret-value"))), "another header");
        assertFalse(check.allows(event(null)), "no headers");
        assertFalse(check.allows(null));
        assertEquals(403, OriginCheck.refused().getStatusCode());
    }

    @Test
    void withoutASecretEverythingPasses() {
        for (var secret : new String[]{null, "", "  "}) {
            var check = new OriginCheck(secret);
            assertTrue(check.allows(event(Map.of())));
            assertTrue(check.allows(event(null)));
        }
    }
}
