package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;

import java.util.Locale;
import java.util.Map;

/**
 * Who calls, from the claims of the Presence session token the HTTP API's
 * JWT authorizer has already verified (it passes every claim through as a
 * string), so they can be trusted. The one place the functions read them.
 *
 * <p>The identity is the <b>provider's</b>, from the token's {@code idp}
 * and {@code idp_sub} claims (Google's {@code https://accounts.google.com}
 * and its {@code sub}, or Apple's {@code https://appleid.apple.com}), not
 * the session token's own {@code iss} and {@code sub}: profiles link
 * subjects as {@code <idp>#<idp_sub>}, as they did when the bearer was
 * Google's ID token itself, so every existing profile keeps its links.
 * {@code email} (always provider-verified) is what rbacr is asked about.
 *
 * @param claims   every claim, empty without a token
 * @param iss      the identity provider's issuer ({@code idp}), or null
 * @param sub      the subject at the provider ({@code idp_sub}), or null
 * @param email    the {@code email} claim as sent (not normalized), or null
 * @param verified the {@code email_verified} claim: the provider checked the email
 * @param hd       the {@code hd} claim, lowercase: the Google Workspace domain
 *                 that manages the account, or null for a personal account
 *                 (Gmail, another address registered as a Google account, Apple)
 */
record Caller(Map<String, String> claims, String iss, String sub, String email, boolean verified, String hd) {

    /** The caller of {@code event}. */
    static Caller from(APIGatewayV2HTTPEvent event) {
        var claims = claims(event);
        var hd = blankToNull(claims.get("hd"));
        return new Caller(claims, blankToNull(claims.get("idp")), blankToNull(claims.get("idp_sub")),
                claims.get("email"), "true".equalsIgnoreCase(claims.getOrDefault("email_verified", "")),
                hd == null ? null : hd.toLowerCase(Locale.ROOT));
    }

    /** A caller with just these claims, as the authorizer passes them (tests). */
    static Caller of(Map<String, String> claims) {
        var event = new APIGatewayV2HTTPEvent();
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        event.setRequestContext(APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build());
        return from(event);
    }

    /** The email, trimmed and lowercase, if the provider verified it; else null. */
    String verifiedEmail() {
        return verified && email != null && !email.isBlank() ? email.strip().toLowerCase(Locale.ROOT) : null;
    }

    /** Whether the token names a provider identity ({@code idp} and {@code idp_sub}). */
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
