package presence.payments;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;

import java.util.Locale;
import java.util.Map;

/**
 * Who is calling: the one place the payments API reads the caller's
 * identity from a request, so a new kind of token (another sign-in) needs
 * a change here only.
 *
 * <p>Today the HTTP API's JWT authorizer verifies a Google ID token and
 * passes its claims through; the caller is its {@code email}, when Google
 * verified it ({@code email_verified}). Admin rights, store purchases and
 * rbacr grants are all keyed by that email.
 */
final class Identity {

    private Identity() {
    }

    /** The caller's email, lowercase, if its issuer verified it; else null. */
    static String verifiedEmail(APIGatewayV2HTTPEvent event) {
        return verifiedEmail(claims(event));
    }

    /** The email in verified {@code claims}, lowercase, if verified; else null. */
    static String verifiedEmail(Map<String, String> claims) {
        var email = claims.get("email");
        var verified = "true".equalsIgnoreCase(claims.getOrDefault("email_verified", ""));
        if (!verified || email == null || email.isBlank()) {
            return null;
        }
        var normalized = email.strip().toLowerCase(Locale.ROOT);
        // An address, and short enough to be a key.
        return normalized.length() <= 254 && normalized.matches("[^@\\s\"\\\\]+@[^@\\s\"\\\\]+") ? normalized : null;
    }

    /** The claims the JWT authorizer verified and passed through; empty without a token. */
    private static Map<String, String> claims(APIGatewayV2HTTPEvent event) {
        var context = event == null ? null : event.getRequestContext();
        var authorizer = context == null ? null : context.getAuthorizer();
        var jwt = authorizer == null ? null : authorizer.getJwt();
        var claims = jwt == null ? null : jwt.getClaims();
        return claims == null ? Map.of() : claims;
    }
}
