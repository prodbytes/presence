package presence.auth;

import java.security.SecureRandom;
import java.time.Clock;

/**
 * What account deletion must do to an identity's sign-ins ({@link #end}):
 * revoke every Presence session of it (its refresh tokens stop working at
 * once; session tokens already issued expire within the hour), revoke its
 * Apple refresh token at Apple (Sign in with Apple's requirement), and
 * forget what's kept of it (its name).
 *
 * <p>The function that calls it needs the session function's settings
 * ({@code SESSIONS_TABLE}, {@code IDENTITIES_TABLE}, and for Apple {@code
 * APPLE_TEAM_ID}, {@code APPLE_KEY_ID}, {@code APPLE_KEY_PARAMETER}, {@code
 * DATA_KEY_ARN}) and permissions (the sessions table's {@code subject}
 * index and {@code UpdateItem}, the identities table's {@code GetItem},
 * {@code UpdateItem} and {@code DeleteItem}, {@code ssm:GetParameter} on
 * the key's parameter and {@code kms:Decrypt} on the data key); see
 * presence_api_auth/template.yaml's SessionFunction.
 */
final class AccountSessions {

    private final Sessions sessions;
    private final Identities identities;
    private final AppleAccounts apple;

    AccountSessions(Sessions sessions, Identities identities, AppleAccounts apple) {
        this.sessions = sessions;
        this.identities = identities;
        this.apple = apple;
    }

    static AccountSessions fromEnvironment() {
        var store = DynamoSessions.fromEnvironment();
        return new AccountSessions(new Sessions(store, new SecureRandom(), Clock.systemUTC()), store,
                AppleAccounts.fromEnvironment(store));
    }

    /**
     * Ends {@code subject}'s ({@code <idp>#<sub>}) sign-ins for good. True
     * when everything is done; false when Apple couldn't be told (the
     * Apple token is kept, so calling again retries).
     */
    boolean end(String subject) {
        sessions.revokeAll(subject);
        if (!apple.revoke(subject)) {
            return false;
        }
        identities.delete(subject);
        return true;
    }
}
