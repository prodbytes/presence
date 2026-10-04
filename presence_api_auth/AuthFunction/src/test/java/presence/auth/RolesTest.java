package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RolesTest {

    private final Map<String, Set<String>> table = Map.of(
            "ana@example.com", Set.of("viewer"),
            "julia@nu01.com", Set.of("owner"),
            "eve@example.com", Set.of(Roles.ROOT, Roles.USER));
    private final Roles roles = new Roles(Set.of("nu01.com", " Example.ORG "), Set.of(" Root@Gmail.com "),
            email -> table.getOrDefault(email, Set.of()));

    @Test
    void nobodyHasRolesByDefault() {
        assertEquals(Set.of(), roles.of("someone@example.com", true));
    }

    @Test
    void verifiedRootDomainsGetEveryRole() {
        assertEquals(Set.of("presence_admin", "presence_root", "presence_user"), roles.of("Bob@NU01.com", true));
        assertEquals(Set.of("presence_admin", "presence_root", "presence_user"), roles.of("carol@example.org", true));
    }

    @Test
    void verifiedRootEmailsGetEveryRole() {
        assertEquals(Set.of("presence_admin", "presence_root", "presence_user"), roles.of(" root@GMAIL.com", true));
        assertEquals(Set.of(), roles.of("root@gmail.com", false));
        // The whole address: not the domain, nor a longer one.
        assertEquals(Set.of(), roles.of("other@gmail.com", true));
        assertEquals(Set.of(), roles.of("xroot@gmail.com", true));
    }

    @Test
    void onlyTheAllowlistGivesRoot() {
        // The roles table can't make a root.
        assertEquals(Set.of(Roles.USER), roles.of("eve@example.com", true));
    }

    @Test
    void domainsAndRolesComeFromCommaSeparatedSettings() {
        assertEquals(Set.of("nu01.com", "example.org"), AuthHandler.list(" nu01.com, ,example.org"));
        assertEquals(Set.of(), AuthHandler.list(null));
    }

    @Test
    void theDomainMustMatchExactlyAndBeVerified() {
        assertEquals(Set.of(), roles.of("bob@nu01.com", false));
        assertEquals(Set.of(), roles.of("bob@evilnu01.com", true));
        assertEquals(Set.of(), roles.of("bob@nu01.com.evil.example", true));
        assertEquals(Set.of(), roles.of("bob@sub.nu01.com", true));
    }

    @Test
    void theTableDeclaresRolesByEmail() {
        assertEquals(Set.of("viewer"), roles.of(" ANA@example.com ", true));
        assertEquals(Set.of("owner", "presence_admin", "presence_root", "presence_user"), roles.of("julia@nu01.com", true));
    }

    @Test
    void unverifiedOrMissingEmailsGetNothing() {
        assertEquals(Set.of(), roles.of("ana@example.com", false));
        assertEquals(Set.of(), roles.of(null, true));
        assertEquals(Set.of(), roles.of(" ", true));
    }

    @Test
    void theHandlerReturnsTheRolesAsJson() {
        var handler = new AuthHandler(roles, profiles());
        var response = handler.handleRequest(event(Map.of(
                "email", "julia@nu01.com", "email_verified", "true")), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("application/json", response.getHeaders().get("Content-Type"));
        assertEquals("no-store", response.getHeaders().get("Cache-Control"));
        assertEquals("{\"email\":\"julia@nu01.com\",\"profile\":null,\"roles\":[\"owner\",\"presence_admin\",\"presence_root\",\"presence_user\"]}", response.getBody());

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
                + "\"settings\":{\"oidc\":true,\"aws\":false}}", response.getBody());
    }

    @Test
    void theAnonymousUserGetsEveryRoleInDev() {
        var handler = new AuthHandler(roles, profiles(), ExecutionMode.DEV);
        assertEquals("{\"mode\":\"DEV\",\"roles\":[\"presence_admin\",\"presence_anonymous\",\"presence_root\",\"presence_user\"],"
                + "\"settings\":{\"oidc\":false,\"aws\":false}}",
                handler.handleRequest(anonymous(), null).getBody());
    }

    @Test
    void theAnonymousRouteSaysWhichSettingsAreSet() {
        var handler = new AuthHandler(roles, profiles(), ExecutionMode.RBAC,
                Settings.of("123-abc.apps.googleusercontent.com", "us-east-1:pool", "bucket"));
        assertTrue(handler.handleRequest(anonymous(), null).getBody()
                .endsWith(",\"settings\":{\"oidc\":true,\"aws\":true}}"));
        assertEquals(new Settings(false, false), Settings.of(null, " ", ""));
        // AWS sync needs both the identity pool and the bucket.
        assertEquals(new Settings(true, false), Settings.of("id", "us-east-1:pool", null));
        assertEquals(new Settings(false, false), Settings.of("", null, "bucket"));
    }

    @Test
    void signedInUsersStillGetTheirOwnRolesInRbac() {
        var handler = new AuthHandler(roles, profiles(), ExecutionMode.RBAC);
        var response = handler.handleRequest(event(Map.of("email", "x@example.com", "email_verified", "true")), null);
        assertEquals("{\"email\":\"x@example.com\",\"profile\":null,\"roles\":[]}", response.getBody());
    }

    private static APIGatewayV2HTTPEvent anonymous() {
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(AuthHandler.ANONYMOUS_ROUTE);
        return event;
    }

    @Test
    void emailsAreEscapedInTheResponse() {
        var handler = new AuthHandler(new Roles(Set.of("nu01.com"), Set.of(), e -> Set.of()), profiles());
        var response = handler.handleRequest(event(Map.of("email", "a\"b@example.com", "email_verified", "true")), null);
        assertEquals("{\"email\":\"a\\\"b@example.com\",\"profile\":null,\"roles\":[]}", response.getBody());
    }

    /** Profiles for tokens without a subject: none. */
    static Profiles profiles() {
        return new Profiles(new MemoryProfiles());
    }

    static APIGatewayV2HTTPEvent event(Map<String, String> claims) {
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        var context = APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build();
        return APIGatewayV2HTTPEvent.builder().withRequestContext(context).build();
    }
}
