package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
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
    void theModeIsDevOnlyWithoutAnOidcClient() {
        assertEquals(ExecutionMode.DEV, ExecutionMode.of(null));
        assertEquals(ExecutionMode.DEV, ExecutionMode.of(" "));
        assertEquals(ExecutionMode.RBAC, ExecutionMode.of("123-abc.apps.googleusercontent.com"));
    }

    @Test
    void theAnonymousUserMayOnlySignInUnderRbac() {
        var handler = new AuthHandler(ExecutionMode.RBAC);
        var response = handler.handleRequest(anonymous(), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("application/json", response.getHeaders().get("Content-Type"));
        assertEquals("no-store", response.getHeaders().get("Cache-Control"));
        assertEquals("{\"mode\":\"RBAC\",\"roles\":[\"presence_anonymous\"],"
                + "\"settings\":{\"oidc\":true,\"aws\":false,\"rbacr\":false}}", response.getBody());
    }

    @Test
    void theAnonymousRouteAnswersExactlyWhatTheDeploySmokeCheckExpects() {
        // Maintenance mode is rbacr's now: no "maintenance" here.
        var handler = new AuthHandler(ExecutionMode.RBAC,
                Settings.of("123-abc.apps.googleusercontent.com", "us-east-1:pool", "bucket", "rbacr_token"));
        var body = handler.handleRequest(anonymous(), null).getBody();
        assertEquals("{\"mode\":\"RBAC\",\"roles\":[\"presence_anonymous\"],"
                + "\"settings\":{\"oidc\":true,\"aws\":true,\"rbacr\":true}}", body);
        assertFalse(body.contains("maintenance"));
    }

    @Test
    void theHandlerAnswersOnlyTheAnonymousRoute() {
        // GET /api/auth is gone: the app asks rbacr for its roles.
        var event = event(verified("julio@nu01.com"));
        event.setRouteKey("GET /api/auth");
        var response = new AuthHandler(ExecutionMode.RBAC).handleRequest(event, null);
        assertEquals(404, response.getStatusCode());
    }

    @Test
    void theAnonymousUserGetsEveryRoleInDev() {
        var handler = new AuthHandler(ExecutionMode.DEV);
        assertEquals("{\"mode\":\"DEV\",\"roles\":[\"presence_admin\",\"presence_anonymous\",\"presence_premium\",\"presence_root\",\"presence_user\"],"
                + "\"settings\":{\"oidc\":false,\"aws\":false,\"rbacr\":false}}",
                handler.handleRequest(anonymous(), null).getBody());
    }

    @Test
    void theAnonymousRouteSaysWhichSettingsAreSet() {
        var handler = new AuthHandler(ExecutionMode.RBAC,
                Settings.of("123-abc.apps.googleusercontent.com", "us-east-1:pool", "bucket"));
        assertTrue(handler.handleRequest(anonymous(), null).getBody()
                .endsWith(",\"settings\":{\"oidc\":true,\"aws\":true,\"rbacr\":false}}"));
        assertEquals(new Settings(false, false), Settings.of(null, " ", ""));
        // AWS sync needs both the identity pool and the bucket.
        assertEquals(new Settings(true, false), Settings.of("id", "us-east-1:pool", null));
        assertEquals(new Settings(false, false), Settings.of("", null, "bucket"));
        assertEquals(new Settings(true, true, true), Settings.of("id", "pool", "bucket", "rbacr_token"));
        assertEquals(new Settings(true, true, false), Settings.of("id", "pool", "bucket", " "));
    }

    private static final String GOOGLE = "https://accounts.google.com";

    /** A verified Google account, subject {@code sub}. */
    private static Caller caller(String sub, String email) {
        return Caller.of(Map.of("iss", GOOGLE, "sub", sub, "email", email, "email_verified", "true"));
    }

    /** A profile {@code sub} (with {@code email}) owns. */
    private static Profiles.Profile ownedBy(String sub, String email) {
        return new Profiles.Profile("p", "", GOOGLE + "#" + sub, email, null);
    }

    @Test
    void theOwnerSharesNothingWithItself() {
        var owner = caller("pat", "pat@example.com");
        assertEquals(Set.of(), roles.shared(owner, ownedBy("pat", "pat@example.com")));
        // Its own roles are still its own.
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.of(owner, ownedBy("pat", "pat@example.com")));
    }

    @Test
    void aLinkedAccountSharesItsOwnersMembershipAndPremium() {
        var linked = caller("home", "someone@example.com");
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.shared(linked, ownedBy("pat", "pat@example.com")));
        assertEquals(Set.of(Roles.USER), roles.shared(linked, ownedBy("ana", "ana@example.com")));
        // An owner who isn't a member (or has a role the app doesn't use) shares nothing.
        assertEquals(Set.of(), roles.shared(linked, ownedBy("nobody", "nobody@example.com")));
        assertEquals(Set.of(), roles.shared(linked, ownedBy("vic", "vic@example.com")));
        // No profile, or an owner without a verified email: nothing.
        assertEquals(Set.of(), roles.shared(linked, null));
        assertEquals(Set.of(), roles.shared(linked, ownedBy("pat", null)));
        // An unverified caller shares nothing.
        var unverified = Caller.of(Map.of("iss", GOOGLE, "sub", "home", "email", "someone@example.com",
                "email_verified", "false"));
        assertEquals(Set.of(), roles.shared(unverified, ownedBy("pat", "pat@example.com")));
    }

    @Test
    void administrationIsNeverShared() {
        var linked = caller("home", "someone@example.com");
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.shared(linked, ownedBy("boss", "boss@example.com")));
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.shared(linked, ownedBy("julio", "julio@nu01.com")));
    }

    @Test
    void theRolesForAProfileAreTheCallersOwnAndWhatItShares() {
        // ana is free on her own; linked to pat's profile, premium too.
        var ana = caller("ana", "ana@example.com");
        var pats = ownedBy("pat", "pat@example.com");
        assertEquals(Set.of(Roles.USER), roles.of(ana));
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.shared(ana, pats));
        assertEquals(Set.of(Roles.PREMIUM, Roles.USER), roles.of(ana, pats));
        // An admin linked to a free owner keeps its own administration.
        var boss = caller("boss", "boss@example.com");
        assertEquals(Set.of(Roles.ADMIN, Roles.PREMIUM, Roles.USER), roles.of(boss, ownedBy("ana", "ana@example.com")));
    }

    static APIGatewayV2HTTPEvent anonymous() {
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(AuthHandler.ANONYMOUS_ROUTE);
        return event;
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
}
