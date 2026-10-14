package presence.payments;

import java.time.Instant;
import java.util.Set;

/**
 * A Premium subscription bought in a store, as the store itself vouched
 * for it (never as the app said).
 *
 * @param platform     {@code ios} (the App Store) or {@code android} (Google Play)
 * @param purchaseId   what identifies the subscription across renewals:
 *                     Apple's {@code originalTransactionId}, or Google's
 *                     purchase token
 * @param linkedId     a previous purchase this one replaces (Google's
 *                     {@code linkedPurchaseToken}), or null
 * @param productId    one of {@link #PRODUCTS}
 * @param expiresAt    when the paid (or trial) period ends
 * @param accountToken the account token the app set on the purchase
 *                     (Apple's {@code appAccountToken}, Google's {@code
 *                     obfuscatedExternalAccountId}), or null
 * @param test         whether it's a sandbox or test purchase
 * @param acknowledged Google: whether it's acknowledged; Apple: always true
 * @param signedAt     when the store said so: Apple's {@code signedDate}
 *                     (so an older signed state, replayed, can't undo a
 *                     newer one such as a refund); Google's, the lookup's
 *                     time (always current)
 */
record StorePurchase(String platform, String purchaseId, String linkedId, String productId, Instant expiresAt,
                     String accountToken, boolean test, boolean acknowledged, Instant signedAt) {

    static final String IOS = "ios";
    static final String ANDROID = "android";

    /** The app's package (Android) and bundle (iOS) ID. */
    static final String APP_ID = "com.nu01.presence";

    /** The Premium subscriptions, the same IDs in both stores. */
    static final Set<String> PRODUCTS = Set.of("presence.premium.monthly", "presence.premium.yearly");

    /** Why a store refused, or didn't confirm, a purchase. */
    static final class Invalid extends Exception {
        Invalid(String message) {
            super(message);
        }
    }

    /** The store didn't answer (or failed): try again later. */
    static final class Unavailable extends Exception {
        Unavailable(String message) {
            super(message);
        }
    }
}
