package presence.auth;

import java.time.Instant;
import java.util.Optional;

/**
 * What Presence keeps of a provider identity ({@code <idp>#<sub>}) beyond
 * its sessions: the name Sign in with Apple gives only at the first
 * sign-in (so later sessions and other devices still have it), and, when
 * the stack has Apple's key, the Apple refresh token (KMS-encrypted) that
 * revokes the user's Apple sign-in when their account is deleted, as Apple
 * requires ({@link AppleAccounts}).
 */
interface Identities {

    /**
     * @param name              the name to put in its tokens, or null
     * @param appleClientId     the client the Apple refresh token is for, or null
     * @param appleRefreshToken the Apple refresh token, encrypted (base64), or null
     */
    record Identity(String subject, String name, String appleClientId, String appleRefreshToken) {
    }

    Optional<Identity> get(String subject);

    /** Keeps {@code name} as the identity's. */
    void saveName(String subject, String name, Instant at);

    /** Keeps the identity's Apple refresh token, encrypted, for {@code clientId}. */
    void saveAppleToken(String subject, String clientId, String encrypted, Instant at);

    /** Forgets the identity's Apple refresh token (revoked). */
    void clearAppleToken(String subject);

    /** Forgets the identity (account deletion). */
    void delete(String subject);
}
