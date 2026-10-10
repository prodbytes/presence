package presence.auth;

import org.junit.jupiter.api.Test;
import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityResponse;
import software.amazon.awssdk.services.cognitoidentity.model.NotAuthorizedException;
import software.amazon.awssdk.services.iot.IotClient;
import software.amazon.awssdk.services.iot.model.AttachPolicyRequest;
import software.amazon.awssdk.services.iot.model.AttachPolicyResponse;
import software.amazon.awssdk.services.iot.model.IotException;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProfileBackendTest {

    private static final String DEV = "login.presence.profiles";

    /** As Cognito, for an identity Google sign-in made: a profile ID links to it only beside its Google login. */
    private static final class Cognito implements CognitoIdentityClient {
        final List<Map<String, String>> calls = new ArrayList<>();
        final List<Map<String, String>> tags = new ArrayList<>();
        String linkedProfile;

        @Override
        public GetOpenIdTokenForDeveloperIdentityResponse getOpenIdTokenForDeveloperIdentity(
                GetOpenIdTokenForDeveloperIdentityRequest request) {
            var logins = request.logins();
            calls.add(logins);
            tags.add(request.principalTags());
            var profile = logins.get(DEV);
            if (linkedProfile == null && "google-token".equals(logins.get(ProfileBackend.GOOGLE))) {
                linkedProfile = profile;
            }
            if (linkedProfile == null || !linkedProfile.equals(profile)) {
                throw NotAuthorizedException.builder().message("Logins don't match.").build();
            }
            return GetOpenIdTokenForDeveloperIdentityResponse.builder()
                    .identityId(request.identityId()).token("token").build();
        }

        @Override
        public String serviceName() {
            return "cognito-identity";
        }

        @Override
        public void close() {
        }
    }

    private final Cognito cognito = new Cognito();
    private final ProfileBackend backend = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket");

    @Test
    void theFirstTokenLinksTheProfileWithTheGoogleLogin() {
        assertEquals("token", backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token"));
        assertEquals(List.of(
                Map.of(DEV, "savvy_plaice"),
                Map.of(DEV, "savvy_plaice", ProfileBackend.GOOGLE, "google-token")), cognito.calls);

        // Linked: the profile ID alone from now on, from any linked account.
        cognito.calls.clear();
        assertEquals("token", backend.openIdToken("us-east-1:id", "savvy_plaice", "member-token"));
        assertEquals(List.of(Map.of(DEV, "savvy_plaice")), cognito.calls);
    }

    @Test
    void administratorsTokensAlsoCarryTheAdminTag() {
        backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token", ProfileHandler.FREE, true);
        assertEquals(List.of(Map.of("tier", "free", "admin", "true"), Map.of("tier", "free", "admin", "true")),
                cognito.tags);
        cognito.tags.clear();
        // Linked now: one try, without the admin tag for a member.
        backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token", ProfileHandler.FREE, false);
        assertEquals(List.of(Map.of("tier", "free")), cognito.tags);
    }

    @Test
    void tokensCarryTheTierAsAPrincipalTag() {
        backend.openIdToken("us-east-1:id", "savvy_plaice", "google-token", ProfileHandler.PREMIUM);
        // Both tries (unlinked, then with the Google login) are tagged.
        assertEquals(List.of(Map.of("tier", "premium"), Map.of("tier", "premium")), cognito.tags);
        cognito.tags.clear();
        // Without a tier (a link code's token): free, never premium.
        backend.openIdToken("us-east-1:id", "savvy_plaice", null);
        assertEquals(List.of(Map.of("tier", "free")), cognito.tags);
    }

    /** AWS IoT's control plane: records AttachPolicy calls, or fails them. */
    private static final class Iot implements IotClient {
        final List<String> attached = new ArrayList<>();
        RuntimeException fails;

        @Override
        public AttachPolicyResponse attachPolicy(AttachPolicyRequest request) {
            if (fails != null) {
                throw fails;
            }
            attached.add(request.policyName() + " -> " + request.target());
            return AttachPolicyResponse.builder().build();
        }

        @Override
        public String serviceName() {
            return "iot";
        }

        @Override
        public void close() {
        }
    }

    @Test
    void liveSyncAttachesThePolicyToTheIdentityOncePerInstance() {
        var iot = new Iot();
        var live = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "presence-live-sync");
        live.allowLiveSync("us-east-1:id");
        live.allowLiveSync("us-east-1:id");
        live.allowLiveSync("us-east-1:other");
        assertEquals(List.of("presence-live-sync -> us-east-1:id", "presence-live-sync -> us-east-1:other"),
                iot.attached);
    }

    @Test
    void aFailedAttachDoesntFailCredentialsAndIsTriedAgain() {
        var iot = new Iot();
        var live = new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "presence-live-sync");
        iot.fails = IotException.builder().message("throttled").statusCode(429).build();
        live.allowLiveSync("us-east-1:id");
        iot.fails = null;
        live.allowLiveSync("us-east-1:id");
        assertEquals(List.of("presence-live-sync -> us-east-1:id"), iot.attached);
    }

    @Test
    void withoutAPolicyNothingIsAttached() {
        var iot = new Iot();
        new ProfileBackend(null, cognito, null, "codes", "pool", DEV, "bucket", iot, "").allowLiveSync("us-east-1:id");
        backend.allowLiveSync("us-east-1:id");
        assertEquals(List.of(), iot.attached);
    }

    @Test
    void anotherGoogleAccountCantLinkIt() {
        assertThrows(NotAuthorizedException.class,
                () -> backend.openIdToken("us-east-1:id", "savvy_plaice", "member-token"));
        assertThrows(NotAuthorizedException.class,
                () -> backend.openIdToken("us-east-1:id", "savvy_plaice", null));
    }
}
