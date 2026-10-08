package presence.auth;

/**
 * Which of the settings the system expects are set, as the app's health line
 * shows them: an OIDC client ({@code GOOGLE_WEB_CLIENT_ID}) and AWS cloud
 * sync ({@code COGNITO_IDENTITY_POOL_ID} and {@code USER_DATA_BUCKET}),
 * and rbacr ({@code RBACR_TOKEN}), which says who is premium. Only whether
 * each is set is reported, never a value.
 *
 * @param oidc  whether an OIDC client is configured
 * @param aws   whether both the identity pool and the user-data bucket are
 * @param rbacr whether an rbacr token is (without it, nobody is premium)
 */
public record Settings(boolean oidc, boolean aws, boolean rbacr) {

    /** Without rbacr. */
    public Settings(boolean oidc, boolean aws) {
        this(oidc, aws, false);
    }

    public static Settings of(String oidcClientId, String identityPoolId, String userDataBucket) {
        return of(oidcClientId, identityPoolId, userDataBucket, null);
    }

    public static Settings of(String oidcClientId, String identityPoolId, String userDataBucket,
                              String rbacrToken) {
        return new Settings(isSet(oidcClientId), isSet(identityPoolId) && isSet(userDataBucket),
                isSet(rbacrToken));
    }

    /** From the function's environment (see template.yaml). */
    public static Settings fromEnvironment() {
        return of(System.getenv("GOOGLE_WEB_CLIENT_ID"),
                System.getenv("COGNITO_IDENTITY_POOL_ID"),
                System.getenv("USER_DATA_BUCKET"),
                System.getenv("RBACR_TOKEN"));
    }

    /** As in {@code GET /api/auth/anonymous}: {@code {"oidc":true,"aws":false,"rbacr":true}}. */
    public String toJson() {
        return "{\"oidc\":" + oidc + ",\"aws\":" + aws + ",\"rbacr\":" + rbacr + "}";
    }

    private static boolean isSet(String value) {
        return value != null && !value.isBlank();
    }
}
