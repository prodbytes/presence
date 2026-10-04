package presence.auth;

import java.time.Instant;
import java.util.List;
import java.util.Optional;

/**
 * A profile is one person: their folder in the user-data bucket (a Cognito
 * identity) and every Google account that signs in to it. Each account
 * (by its Google {@code sub}, which never changes, unlike the email)
 * belongs to one profile; a new account gets a profile of its own, and a
 * link code moves another account into it.
 */
final class Profiles {

    private Profiles() {
    }

    /**
     * One Google account in the accounts table.
     *
     * @param sub        the Google account ID (the ID token's {@code sub}); the table's key
     * @param email      its verified email, as last seen
     * @param profileId  the profile: the developer user identifier Cognito knows it by
     * @param identityId the profile's Cognito identity ID, its prefix in the bucket
     * @param ownerEmail the email of the account that made the profile, whose roles linked accounts share
     * @param owner      whether this account made the profile (and so can't be unlinked from it)
     * @param linkedAt   when it joined the profile
     */
    record Account(String sub, String email, String profileId, String identityId, String ownerEmail,
                   boolean owner, Instant linkedAt) {
    }

    /** A link code, as stored (by its hash): which profile it joins, and until when. */
    record LinkCode(String profileId, String identityId, String ownerEmail, String createdBy, Instant expiresAt) {
    }

    /** Where profiles live: DynamoDB, Cognito and S3 in AWS ({@link ProfileBackend}); fakes in tests. */
    interface Backend {
        Optional<Account> account(String sub);

        /** Adds {@code account} unless its {@code sub} is already there; false if it was. */
        boolean create(Account account);

        /** Adds or replaces {@code account}. */
        void put(Account account);

        void delete(String sub);

        /** Every account of the profile. */
        List<Account> members(String profileId);

        /** Keeps {@code code} under {@code hash} until it expires. */
        void saveCode(String hash, LinkCode code);

        /** Removes and returns the code under {@code hash}, if it's there and hasn't expired by {@code now}. */
        Optional<LinkCode> takeCode(String hash, Instant now);

        /**
         * The Cognito identity the Google ID token signs in to directly
         * ({@code GetId}): where the account's data went before profiles,
         * or a new, empty identity.
         */
        String googleIdentity(String googleIdToken);

        /**
         * An OpenID token for the profile's identity
         * ({@code GetOpenIdTokenForDeveloperIdentity}), which the app trades
         * for AWS credentials. The first call links the profile to the
         * identity.
         */
        String openIdToken(String identityId, String profileId);

        /** Whether the identity's folder in the bucket holds nothing. */
        boolean folderEmpty(String identityId);
    }
}
