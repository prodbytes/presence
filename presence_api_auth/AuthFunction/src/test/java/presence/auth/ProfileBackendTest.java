package presence.auth;

import org.junit.jupiter.api.Test;
import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityRequest;
import software.amazon.awssdk.services.cognitoidentity.model.GetOpenIdTokenForDeveloperIdentityResponse;
import software.amazon.awssdk.services.cognitoidentity.model.NotAuthorizedException;

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
        String linkedProfile;

        @Override
        public GetOpenIdTokenForDeveloperIdentityResponse getOpenIdTokenForDeveloperIdentity(
                GetOpenIdTokenForDeveloperIdentityRequest request) {
            var logins = request.logins();
            calls.add(logins);
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
    void anotherGoogleAccountCantLinkIt() {
        assertThrows(NotAuthorizedException.class,
                () -> backend.openIdToken("us-east-1:id", "savvy_plaice", "member-token"));
        assertThrows(NotAuthorizedException.class,
                () -> backend.openIdToken("us-east-1:id", "savvy_plaice", null));
    }
}
