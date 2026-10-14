package presence.payments;

import java.time.Instant;
import java.util.Map;
import java.util.Set;

/**
 * The App Store's side of store purchases: StoreKit 2 signed transactions
 * (what the app sends, the plugin's {@code serverVerificationData}) and App
 * Store Server Notifications V2, each verified with {@link AppleJws}, then
 * checked to be Presence's ({@link StorePurchase#APP_ID}), a Premium
 * subscription ({@link StorePurchase#PRODUCTS}), and from the production
 * App Store, or the sandbox when {@code allowSandbox} (the RC).
 */
final class AppleStore {

    /** App Store Connect's environments: real purchases, and TestFlight's and development's. */
    static final String PRODUCTION = "Production";
    static final String SANDBOX = "Sandbox";

    private final AppleJws jws;
    private final boolean allowSandbox;

    AppleStore(AppleJws jws, boolean allowSandbox) {
        this.jws = jws;
        this.allowSandbox = allowSandbox;
    }

    /**
     * A transaction as Apple signed it.
     *
     * @param purchase  the purchase it belongs to
     * @param revoked   whether Apple revoked it (a refund, or Family
     *                  Sharing taken away)
     */
    record Transaction(StorePurchase purchase, boolean revoked) {
    }

    /**
     * A notification as Apple signed it.
     *
     * @param type         {@code notificationType} ({@code DID_RENEW},
     *                     {@code REFUND}, {@code EXPIRED}, ...)
     * @param subtype      {@code subtype}, or null
     * @param transaction  its transaction, or null (a {@code TEST})
     * @param graceUntil   the renewal info's {@code gracePeriodExpiresDate}
     *                     (billing retry with service kept), or null
     * @param signedAt     when Apple signed the notification
     */
    record Notification(String type, String subtype, Transaction transaction, Instant graceUntil,
                        Instant signedAt) {
    }

    /** The purchase in a signed transaction the app sent: Presence's, current, not revoked. */
    StorePurchase purchase(String signedTransaction, Instant now) throws StorePurchase.Invalid {
        var transaction = transaction(signedTransaction);
        if (transaction.revoked()) {
            throw new StorePurchase.Invalid("Apple revoked this purchase");
        }
        if (!transaction.purchase().expiresAt().isAfter(now)) {
            throw new StorePurchase.Invalid("this subscription has expired");
        }
        return transaction.purchase();
    }

    /** A signed transaction's content, checked to be a Premium subscription of Presence's. */
    Transaction transaction(String signedTransaction) throws StorePurchase.Invalid {
        Map<String, Object> payload;
        try {
            payload = jws.verify(signedTransaction);
        } catch (AppleJws.InvalidJws e) {
            throw new StorePurchase.Invalid("the App Store's signature doesn't verify (" + e.getMessage() + ")");
        }
        if (!StorePurchase.APP_ID.equals(JsonReader.string(payload, "bundleId"))) {
            throw new StorePurchase.Invalid("not a purchase in Presence");
        }
        var test = environment(JsonReader.string(payload, "environment"));
        var productId = JsonReader.string(payload, "productId");
        if (productId == null || !StorePurchase.PRODUCTS.contains(productId)) {
            throw new StorePurchase.Invalid("not a Premium subscription");
        }
        if (!"Auto-Renewable Subscription".equals(JsonReader.string(payload, "type"))) {
            throw new StorePurchase.Invalid("not an auto-renewable subscription");
        }
        var original = JsonReader.string(payload, "originalTransactionId");
        var expires = JsonReader.number(payload, "expiresDate");
        var signed = JsonReader.number(payload, "signedDate");
        if (original == null || !original.matches("[0-9]{1,32}") || expires == null || signed == null) {
            throw new StorePurchase.Invalid("the transaction lacks its ID, expiry or signing date");
        }
        var token = JsonReader.string(payload, "appAccountToken");
        var revoked = payload.get("revocationDate") != null;
        return new Transaction(new StorePurchase(StorePurchase.IOS, original, null, productId,
                Instant.ofEpochMilli(expires), token, test, true, Instant.ofEpochMilli(signed)), revoked);
    }

    /** A notification's body ({@code {"signedPayload": "..."}}), verified, with its transaction. */
    Notification notification(String body) throws StorePurchase.Invalid {
        Map<String, Object> outer;
        try {
            outer = JsonReader.object(body);
        } catch (IllegalArgumentException e) {
            throw new StorePurchase.Invalid("not a notification");
        }
        Map<String, Object> payload;
        try {
            payload = jws.verify(JsonReader.string(outer, "signedPayload"));
        } catch (AppleJws.InvalidJws e) {
            throw new StorePurchase.Invalid("the notification's signature doesn't verify (" + e.getMessage() + ")");
        }
        var type = JsonReader.string(payload, "notificationType");
        if (type == null || !type.matches("[A-Z_]{1,64}")) {
            throw new StorePurchase.Invalid("a notification without its type");
        }
        var subtype = JsonReader.string(payload, "subtype");
        var signed = JsonReader.number(payload, "signedDate");
        if (signed == null) {
            throw new StorePurchase.Invalid("a notification without its signing date");
        }
        var signedAt = Instant.ofEpochMilli(signed);
        var data = JsonReader.child(payload, "data");
        if (data == null) {
            // TEST notifications, and summaries of other kinds, carry none.
            return new Notification(type, subtype, null, null, signedAt);
        }
        if (!StorePurchase.APP_ID.equals(JsonReader.string(data, "bundleId"))) {
            throw new StorePurchase.Invalid("not a notification for Presence");
        }
        environment(JsonReader.string(data, "environment"));
        var signedTransaction = JsonReader.string(data, "signedTransactionInfo");
        var transaction = signedTransaction == null ? null : transaction(signedTransaction);
        Instant grace = null;
        var signedRenewal = JsonReader.string(data, "signedRenewalInfo");
        if (signedRenewal != null) {
            try {
                var renewal = jws.verify(signedRenewal);
                var until = JsonReader.number(renewal, "gracePeriodExpiresDate");
                grace = until == null ? null : Instant.ofEpochMilli(until);
            } catch (AppleJws.InvalidJws e) {
                throw new StorePurchase.Invalid("the renewal info's signature doesn't verify");
            }
        }
        return new Notification(type, subtype, transaction, grace, signedAt);
    }

    /** Whether {@code environment} is the sandbox; refuses what this stage doesn't take. */
    private boolean environment(String environment) throws StorePurchase.Invalid {
        if (PRODUCTION.equals(environment)) {
            return false;
        }
        if (SANDBOX.equals(environment) && allowSandbox) {
            return true;
        }
        throw new StorePurchase.Invalid("a purchase in the App Store's " + environment
                + " environment isn't taken here");
    }

    /** Notification types after which the subscription no longer gives Premium. */
    static final Set<String> ENDS = Set.of("REFUND", "REVOKE", "EXPIRED", "GRACE_PERIOD_EXPIRED");
}
