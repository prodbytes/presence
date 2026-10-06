package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;

import java.util.Locale;
import java.util.Map;

/**
 * Who calls, from the claims of the Google ID token the HTTP API's JWT
 * authorizer has already verified (it passes every claim through as a
 * string), so they can be trusted.
 *
 * @param claims   every claim, empty without a token
 * @param iss      the issuer, or null
 * @param sub      the subject at the issuer, or null
 * @param email    the {@code email} claim as sent (not normalized), or null
 * @param verified the {@code email_verified} claim: Google checked the email
 * @param hd       the {@code hd} claim, lowercase: the Google Workspace domain
 *                 that manages the account, or null for a personal account
 *                 (Gmail, or another address registered as a Google account)
 * @param idToken  the bearer token itself, or empty
 */
record Caller(Map<String, String> claims, String iss, String sub, String email, boolean verified, String hd,
              String idToken) {

    /** The caller of {@code event}. */
    static Caller from(APIGatewayV2HTTPEvent event) {
        var claims = claims(event);
        var hd = blankToNull(claims.get("hd"));
        return new Caller(claims, blankToNull(claims.get("iss")), blankToNull(claims.get("sub")),
                claims.get("email"), "true".equalsIgnoreCase(claims.getOrDefault("email_verified", "")),
                hd == null ? null : hd.toLowerCase(Locale.ROOT), Http.bearer(event));
    }

    /** A caller with just these claims, as the authorizer passes them (tests). */
    static Caller of(Map<String, String> claims) {
        var event = new APIGatewayV2HTTPEvent();
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        event.setRequestContext(APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build());
        return from(event);
    }

    /** The email, trimmed and lowercase, if Google verified it; else null. */
    String verifiedEmail() {
        return verified && email != null && !email.isBlank() ? email.strip().toLowerCase(Locale.ROOT) : null;
    }

    /** Whether the token names a subject (an issuer and a {@code sub}). */
    boolean hasSubject() {
        return iss != null && sub != null;
    }

    /** The subject's key in the links table ({@link Profiles#subject}); null without one. */
    String subject() {
        return hasSubject() ? Profiles.subject(iss, sub) : null;
    }

    private static Map<String, String> claims(APIGatewayV2HTTPEvent event) {
        var context = event == null ? null : event.getRequestContext();
        var authorizer = context == null ? null : context.getAuthorizer();
        var jwt = authorizer == null ? null : authorizer.getJwt();
        var claims = jwt == null ? null : jwt.getClaims();
        return claims == null ? Map.of() : claims;
    }

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.strip();
    }
}
