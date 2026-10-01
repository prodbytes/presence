package presence.auth;

/**
 * How the API runs, decided by whether an OIDC client (the Google web
 * client, {@code GOOGLE_WEB_CLIENT_ID}) is configured. There's no separate
 * setting, so a stack with sign-in can't be put in {@link #DEV} by mistake.
 */
public enum ExecutionMode {

    /**
     * No OIDC client: nobody can sign in, so the anonymous user gets every
     * role. For local development only.
     */
    DEV,

    /**
     * Sign-in is configured: the anonymous user may only sign in, and
     * signed-in users get their roles (see {@link Roles}).
     */
    RBAC;

    /** @param oidcClientId the OIDC client ID; blank if none is configured */
    public static ExecutionMode of(String oidcClientId) {
        return oidcClientId == null || oidcClientId.isBlank() ? DEV : RBAC;
    }

    /** From {@code GOOGLE_WEB_CLIENT_ID}. */
    public static ExecutionMode fromEnvironment() {
        return of(System.getenv("GOOGLE_WEB_CLIENT_ID"));
    }
}
