package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RolesTest {

    private final List<String> asked = new ArrayList<>();
    private final Map<String, Set<String>> rbacr = Map.of(
            "ana@example.com", Set.of("free"),
            "pat@example.com", Set.of("premium", "free"),
            "boss@example.com", Set.of("admin"),
            "julio@nu01.com", Set.of(Rbacr.ROOT, "admin", "free", "premium"),
            "vic@example.com", Set.of("viewer"));
    private final Roles roles = new Roles(email -> {
        asked.add(email);
        return rbacr.getOrDefault(email, Set.of());
    });

    @Test
    void nobodyHasRolesByDefault() {
        assertEquals(Set.of(), roles.of("someone@example.com", true));
        // A role rbacr has but the app doesn't use gives nothing.
        assertEquals(Set.of(), roles.of("vic@example.com", true));
    }

    @Test
    void rbacrsRolesGiveTheAppsRoles() {
        assertEquals(Set.of(Roles.USER), roles.of("ana@example.com", true));
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.of("pat@example.com", true));
        // Without counting on rbacr's implications: admin alone is all three.
        assertEquals(Set.of(Roles.ADMIN, Roles.PREMIUM, Roles.USER), roles.of("boss@example.com", true));
    }

    @Test
    void rbacrsRootsGetEveryRole() {
        assertEquals(Set.of(Roles.ADMIN, Roles.PREMIUM, Roles.ROOT, Roles.USER), roles.of("julio@nu01.com", true));
        // Root alone (an rbacr whose presence system has no roles yet).
        var root = new Roles(email -> Set.of(Rbacr.ROOT));
        assertEquals(Set.of(Roles.ADMIN, Roles.PREMIUM, Roles.ROOT, Roles.USER), root.of("julio@nu01.com", true));
    }

    @Test
    void rbacrIsAskedAboutTheVerifiedEmailLowerCased() {
        assertEquals(Set.of(Roles.USER), roles.of(" ANA@Example.com ", true));
        assertEquals(List.of("ana@example.com"), asked);
    }

    @Test
    void unverifiedOrMissingEmailsGetNothingAndRbacrIsntAsked() {
        assertEquals(Set.of(), roles.of("ana@example.com", false));
        assertEquals(Set.of(), roles.of(null, true));
        assertEquals(Set.of(), roles.of(" ", true));
        assertEquals(List.of(), asked);
    }

    @Test
    void theHandlerReturnsTheRolesAsJson() {
        var handler = new AuthHandler(roles, profiles());
        var response = handler.handleRequest(event(verified("julio@nu01.com")), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("application/json", response.getHeaders().get("Content-Type"));
        assertEquals("no-store", response.getHeaders().get("Cache-Control"));
        assertEquals("{\"email\":\"julio@nu01.com\",\"profile\":null,\"roles\":[\"presence_admin\","
                + "\"presence_premium\",\"presence_root\",\"presence_user\"]}", response.getBody());

        var none = handler.handleRequest(event(Map.of("email", "x@example.com", "email_verified", "true")), null);
        assertEquals("{\"email\":\"x@example.com\",\"profile\":null,\"roles\":[]}", none.getBody());

        var noClaims = handler.handleRequest(new APIGatewayV2HTTPEvent(), null);
        assertEquals("{\"email\":null,\"profile\":null,\"roles\":[]}", noClaims.getBody());
    }

    @Test
    void theModeIsDevOnlyWithoutAnOidcClient() {
        assertEquals(ExecutionMode.DEV, ExecutionMode.of(null));
        assertEquals(ExecutionMode.DEV, ExecutionMode.of(" "));
        assertEquals(ExecutionMode.RBAC, ExecutionMode.of("123-abc.apps.googleusercontent.com"));
    }

    @Test
    void theAnonymousUserMayOnlySignInUnderRbac() {
        var handler = new AuthHandler(roles, profiles(), ExecutionMode.RBAC);
        var response = handler.handleRequest(anonymous(), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("no-store", response.getHeaders().get("Cache-Control"));
        assertEquals("{\"mode\":\"RBAC\",\"roles\":[\"presence_anonymous\"],"
                + "\"settings\":{\"oidc\":true,\"aws\":false,\"rbacr\":false},"
                + "\"maintenance\":{\"on\":false,\"message\":\"\"}}", response.getBody());
    }

    @Test
    void theAnonymousUserGetsEveryRoleInDev() {
        var handler = new AuthHandler(roles, profiles(), ExecutionMode.DEV);
        assertEquals("{\"mode\":\"DEV\",\"roles\":[\"presence_admin\",\"presence_anonymous\",\"presence_premium\",\"presence_root\",\"presence_user\"],"
                + "\"settings\":{\"oidc\":false,\"aws\":false,\"rbacr\":false},"
                + "\"maintenance\":{\"on\":false,\"message\":\"\"}}",
                handler.handleRequest(anonymous(), null).getBody());
    }

    @Test
    void theAnonymousRouteSaysWhichSettingsAreSet() {
        var handler = new AuthHandler(roles, profiles(), ExecutionMode.RBAC,
                Settings.of("123-abc.apps.googleusercontent.com", "us-east-1:pool", "bucket"));
        assertTrue(handler.handleRequest(anonymous(), null).getBody()
                .contains(",\"settings\":{\"oidc\":true,\"aws\":true,\"rbacr\":false},"));
        assertEquals(new Settings(false, false), Settings.of(null, " ", ""));
        // AWS sync needs both the identity pool and the bucket.
        assertEquals(new Settings(true, false), Settings.of("id", "us-east-1:pool", null));
        assertEquals(new Settings(false, false), Settings.of("", null, "bucket"));
        assertEquals(new Settings(true, true, true), Settings.of("id", "pool", "bucket", "rbacr_token"));
        assertEquals(new Settings(true, true, false), Settings.of("id", "pool", "bucket", " "));
    }

    @Test
    void signedInUsersStillGetTheirOwnRolesInRbac() {
        var handler = new AuthHandler(roles, profiles(), ExecutionMode.RBAC);
        var response = handler.handleRequest(event(Map.of("email", "x@example.com", "email_verified", "true")), null);
        assertEquals("{\"email\":\"x@example.com\",\"profile\":null,\"roles\":[]}", response.getBody());
    }

    static APIGatewayV2HTTPEvent anonymous() {
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(AuthHandler.ANONYMOUS_ROUTE);
        return event;
    }

    @Test
    void emailsAreEscapedInTheResponse() {
        var handler = new AuthHandler(new Roles(e -> Set.of()), profiles());
        var response = handler.handleRequest(event(Map.of("email", "a\"b@example.com", "email_verified", "true")), null);
        assertEquals("{\"email\":\"a\\\"b@example.com\",\"profile\":null,\"roles\":[]}", response.getBody());
    }

    /** Profiles for tokens without a subject: none. */
    static Profiles profiles() {
        return new Profiles(new MemoryProfiles());
    }

    /**
     * A verified Google account's claims; a nu01.com address is one of
     * nu01.com's Workspace (hd).
     */
    static Map<String, String> verified(String email) {
        var claims = new java.util.HashMap<>(Map.of("email", email, "email_verified", "true", "name", "Ana"));
        if (email.endsWith("@nu01.com")) {
            claims.put("hd", "nu01.com");
        }
        return claims;
    }

    static APIGatewayV2HTTPEvent event(Map<String, String> claims) {
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        var context = APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build();
        return APIGatewayV2HTTPEvent.builder().withRequestContext(context).build();
    }

    @Test
    void aFailureAnswersASanitized502() {
        var failing = new Roles(e -> {
            throw new IllegalStateException("arn:aws:dynamodb:us-east-1:123456789012:table/x");
        });
        var response = new AuthHandler(failing, profiles()).handleRequest(event(verified("ana@example.com")), null);
        assertEquals(502, response.getStatusCode());
        assertEquals("{\"error\":\"the auth service failed\",\"cause\":\"IllegalStateException\"}",
                response.getBody());
    }
}
