package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;

class RolesTest {

    private final Map<String, Set<String>> table = Map.of(
            "ana@example.com", Set.of("viewer"),
            "julia@nu01.com", Set.of("owner"));
    private final Roles roles = new Roles("nu01.com", Set.of("admin"),
            email -> table.getOrDefault(email, Set.of()));

    @Test
    void nobodyHasRolesByDefault() {
        assertEquals(Set.of(), roles.of("someone@example.com", true));
    }

    @Test
    void verifiedPrivilegedDomainGetsTheDomainRoles() {
        assertEquals(Set.of("admin"), roles.of("Bob@NU01.com", true));
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
        assertEquals(Set.of("admin", "owner"), roles.of("julia@nu01.com", true));
    }

    @Test
    void unverifiedOrMissingEmailsGetNothing() {
        assertEquals(Set.of(), roles.of("ana@example.com", false));
        assertEquals(Set.of(), roles.of(null, true));
        assertEquals(Set.of(), roles.of(" ", true));
    }

    @Test
    void theHandlerReturnsTheRolesAsJson() {
        var handler = new AuthHandler(roles);
        var response = handler.handleRequest(event(Map.of(
                "email", "julia@nu01.com", "email_verified", "true")), null);
        assertEquals(200, response.getStatusCode());
        assertEquals("application/json", response.getHeaders().get("Content-Type"));
        assertEquals("no-store", response.getHeaders().get("Cache-Control"));
        assertEquals("{\"email\":\"julia@nu01.com\",\"roles\":[\"admin\",\"owner\"]}", response.getBody());

        var none = handler.handleRequest(event(Map.of("email", "x@example.com", "email_verified", "true")), null);
        assertEquals("{\"email\":\"x@example.com\",\"roles\":[]}", none.getBody());

        var noClaims = handler.handleRequest(new APIGatewayV2HTTPEvent(), null);
        assertEquals("{\"email\":null,\"roles\":[]}", noClaims.getBody());
    }

    @Test
    void emailsAreEscapedInTheResponse() {
        var handler = new AuthHandler(new Roles("nu01.com", Set.of(), e -> Set.of()));
        var response = handler.handleRequest(event(Map.of("email", "a\"b@example.com", "email_verified", "true")), null);
        assertEquals("{\"email\":\"a\\\"b@example.com\",\"roles\":[]}", response.getBody());
    }

    private static APIGatewayV2HTTPEvent event(Map<String, String> claims) {
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        var context = APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build();
        return APIGatewayV2HTTPEvent.builder().withRequestContext(context).build();
    }
}
