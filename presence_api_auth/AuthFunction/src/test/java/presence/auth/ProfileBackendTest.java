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

    /** As Cognito: a developer identifier is linked to the identity made for it, and only to that one. */
    private static final class Cognito implements CognitoIdentityClient {
        final List<Map<String, String>> calls = new ArrayList<>();
        final List<Map<String, String>> tags = new ArrayList<>();
        final Map<String, String> identities = new java.util.HashMap<>();

        @Override
        public GetOpenIdTokenForDeveloperIdentityResponse getOpenIdTokenForDeveloperIdentity(
                GetOpenIdTokenForDeveloperIdentityRequest request) {
            var logins = request.logins();
            calls.add(logins);
            tags.add(request.principalTags());
            var profile = logins.get(DEV);
            if (request.identityId() == null) {
                var made = identities.computeIfAbsent(profile, p -> "us-east-1:made-" + p);
                return GetOpenIdTokenForDeveloperIdentityResponse.builder().identityId(made).token("token").build();
            }
            if (!request.identityId().equals(identities.get(profile))) {
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
    void aNewProfileGetsAnIdentityMadeForIt() {
        var identity = backend.newIdentity("savvy_plaice");
        assertEquals("us-east-1:made-savvy_plaice", identity);
        // Asked again (a lost race), Cognito answers the same one.
        assertEquals(identity, backend.newIdentity("savvy_plaice"));
        assertEquals(List.of(Map.of(DEV, "savvy_plaice"), Map.of(DEV, "savvy_plaice")), cognito.calls);

        // Its tokens: the profile ID alone, from any linked account.
        cognito.calls.clear();
        assertEquals("token", backend.openIdToken(identity, "savvy_plaice"));
        assertEquals(List.of(Map.of(DEV, "savvy_plaice")), cognito.calls);
    }

    @Test
    void administratorsTokensAlsoCarryTheAdminTag() {
        var identity = backend.newIdentity("savvy_plaice");
        cognito.tags.clear();
        backend.openIdToken(identity, "savvy_plaice", ProfileHandler.FREE, true);
        assertEquals(List.of(Map.of("tier", "free", "admin", "true")), cognito.tags);
        cognito.tags.clear();
        backend.openIdToken(identity, "savvy_plaice", ProfileHandler.FREE, false);
        assertEquals(List.of(Map.of("tier", "free")), cognito.tags);
    }

    @Test
    void tokensCarryTheTierAsAPrincipalTag() {
        var identity = backend.newIdentity("savvy_plaice");
        cognito.tags.clear();
        backend.openIdToken(identity, "savvy_plaice", ProfileHandler.PREMIUM);
        assertEquals(List.of(Map.of("tier", "premium")), cognito.tags);
        cognito.tags.clear();
        // Without a tier (a link code's token): free, never premium.
        backend.openIdToken(identity, "savvy_plaice");
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
    void anotherProfileCantUseTheIdentity() {
        var identity = backend.newIdentity("savvy_plaice");
        assertThrows(NotAuthorizedException.class, () -> backend.openIdToken(identity, "other_profile"));
    }
}
