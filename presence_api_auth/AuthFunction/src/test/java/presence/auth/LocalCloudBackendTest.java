package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class LocalCloudBackendTest {

    private static final Instant NOW = Instant.parse("2026-10-11T12:00:00Z");
    private static final String GOOGLE = "https://accounts.google.com";

    /** What the local stack keeps in Floci: link codes and the bucket's folders. */
    private final List<String> asked = new ArrayList<>();
    private final ProfileHandler.Backend floci = new ProfileHandler.Backend() {
        @Override
        public void saveCode(String hash, ProfileHandler.LinkCode code) {
            asked.add("saveCode");
        }

        @Override
        public Optional<ProfileHandler.LinkCode> peekCode(String hash, Instant now) {
            return Optional.empty();
        }

        @Override
        public Optional<ProfileHandler.LinkCode> takeCode(String hash, Instant now) {
            return Optional.empty();
        }

        @Override
        public String newIdentity(String profileId) {
            throw new AssertionError("Floci has no Cognito Identity");
        }

        @Override
        public String openIdToken(String identityId, String profileId) {
            throw new AssertionError("Floci has no GetOpenIdTokenForDeveloperIdentity");
        }

        @Override
        public boolean folderEmpty(String identityId) {
            asked.add("folderEmpty " + identityId);
            return true;
        }

        @Override
        public void allowLiveSync(String identityId) {
            throw new AssertionError("Floci's broker has no policies");
        }
    };

    private final LocalCloudBackend local = new LocalCloudBackend(floci, "us-east-1", new SecureRandom(),
            Clock.fixed(NOW, ZoneOffset.UTC));

    @Test
    void aProfileAlwaysGetsTheSameIdentity() {
        var ana = local.newIdentity("happy_quiet_otter");
        assertTrue(ana.matches("us-east-1:[0-9a-f-]{36}"), ana);
        assertEquals(ana, local.newIdentity("happy_quiet_otter"));
        assertEquals(LocalCloudBackend.identityOf("us-east-1", "profile", "happy_quiet_otter"), ana);
        assertNotEquals(ana, local.newIdentity("brave_little_lamp"));
    }

    @Test
    void credentialsInCognitosShapeForAnHour() {
        var json = local.credentials("us-east-1:x").orElseThrow();
        assertTrue(Pattern.matches("\\{\"AccessKeyId\":\"ASIALOCAL[A-Z0-9XY]+\",\"SecretKey\":\"[A-Za-z0-9]+\","
                + "\"SessionToken\":\"[A-Za-z0-9]+\",\"Expiration\":" + NOW.plusSeconds(3600).getEpochSecond() + "}",
                json), json);
        assertNotEquals(json, local.credentials("us-east-1:x").orElseThrow());
    }

    @Test
    void theCredentialsRouteAnswersThemInTheLocalStack() {
        var roles = new Roles(e -> e.equals("julio@nu01.com") ? Set.of("premium") : Set.of());
        var profiles = new Profiles(new MemoryProfiles(), Clock.fixed(NOW, ZoneOffset.UTC), () -> "profile_1");
        var handler = new ProfileHandler(roles, profiles, local, true, new SecureRandom(), "presence-local-user-data");

        var claims = RolesTest.verified("julio@nu01.com");
        claims.put("idp", GOOGLE);
        claims.put("idp_sub", "111");
        var jwt = new APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT();
        jwt.setClaims(claims);
        var authorizer = new APIGatewayV2HTTPEvent.RequestContext.Authorizer();
        authorizer.setJwt(jwt);
        var context = new APIGatewayV2HTTPEvent.RequestContext();
        context.setAuthorizer(authorizer);
        var event = new APIGatewayV2HTTPEvent();
        event.setRequestContext(context);
        event.setRouteKey("POST /api/auth/credentials");
        event.setBody("happy_quiet_otter");

        var response = handler.handleRequest(event, null);

        assertEquals(200, response.getStatusCode(), response.getBody());
        var identity = LocalCloudBackend.identityOf("us-east-1", "profile", "profile_1");
        assertTrue(response.getBody().startsWith("{\"identityId\":\"" + identity + "\",\"token\":\"local\","),
                response.getBody());
        assertTrue(response.getBody().contains(",\"tier\":\"premium\",\"bucket\":\"presence-local-user-data\""
                + ",\"credentials\":{\"AccessKeyId\":\"ASIALOCAL"), response.getBody());
        // Nothing asked of Cognito or IoT (the fake fails if it is).
        assertTrue(asked.isEmpty(), asked.toString());
    }
}
