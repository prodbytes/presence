package presence.auth;

/**
 * Which of the settings the system expects are set, as the app's health line
 * shows them: an OIDC client ({@code GOOGLE_WEB_CLIENT_ID}) and AWS cloud
 * sync ({@code COGNITO_IDENTITY_POOL_ID} and {@code USER_DATA_BUCKET}).
 * Only whether each is set is reported, never a value.
 *
 * @param oidc whether an OIDC client is configured
 * @param aws  whether both the identity pool and the user-data bucket are
 */
public record Settings(boolean oidc, boolean aws) {

    public static Settings of(String oidcClientId, String identityPoolId, String userDataBucket) {
        return new Settings(isSet(oidcClientId), isSet(identityPoolId) && isSet(userDataBucket));
    }

    /** From the function's environment (see template.yaml). */
    public static Settings fromEnvironment() {
        return of(System.getenv("GOOGLE_WEB_CLIENT_ID"),
                System.getenv("COGNITO_IDENTITY_POOL_ID"),
                System.getenv("USER_DATA_BUCKET"));
    }

    /** As in {@code GET /api/auth/anonymous}: {@code {"oidc":true,"aws":false}}. */
    public String toJson() {
        return "{\"oidc\":" + oidc + ",\"aws\":" + aws + "}";
    }

    private static boolean isSet(String value) {
        return value != null && !value.isBlank();
    }
}
