package presence.payments;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Comparator;
import java.util.Locale;
import java.util.function.Supplier;

import static presence.payments.Http.response;

/**
 * Premium bought in the App Store or Google Play (the mobile apps; the web
 * keeps Stripe). Every purchase is verified with its store, server-side,
 * bound to the caller's verified email, and turned into rbacr's {@code
 * premium} grant until the paid period ends ({@link RbacrGrants}).
 * <ul>
 *   <li>{@code GET /api/payments/store}: {@code {"ios", "android",
 *       "accountToken"}}: which stores this stack verifies, and the token
 *       the app puts on its purchases.</li>
 *   <li>{@code POST /api/payments/store/verify} {@code {"platform": "ios" |
 *       "android", "productId", "verificationData"}}: the StoreKit 2 signed
 *       transaction, or Google's purchase token. 200 {@code {"premium":
 *       true, ...}}; 400 a purchase the store doesn't vouch for (or not
 *       current); 403 no verified email; 409 bound to another account; 502
 *       the store or rbacr failed; 503 not configured.</li>
 *   <li>{@code POST /api/payments/store/apple-notifications}: App Store
 *       Server Notifications V2 (no JWT: Apple's signature authenticates
 *       it), which extend or end the grant of a bound purchase.</li>
 *   <li>{@code POST /api/payments/free}: Join free, the caller gets rbacr's
 *       {@code free} role ({@link #JOIN_FREE}).</li>
 * </ul>
 */
final class StorePurchases {

    static final String GET_STORE = "GET /api/payments/store";
    static final String VERIFY = "POST /api/payments/store/verify";
    static final String APPLE_NOTIFICATIONS = "POST /api/payments/store/apple-notifications";

    /** Join free: the caller gets rbacr's {@code free} role, as a nu01.com Free subscription gives. */
    static final String JOIN_FREE = "POST /api/payments/free";

    /** The largest verify body taken (a signed transaction is about 4 KB). */
    static final int MAX_VERIFY = 16 * 1024;

    /** The largest notification taken (a payload with two signed parts, each about 4 KB). */
    static final int MAX_NOTIFICATION = 64 * 1024;

    /** How long Premium outlasts a real subscription's paid period: room for the renewal to reach us. */
    static final Duration GRACE = Duration.ofDays(2);

    /** The same for sandbox and test purchases, which renew in minutes. */
    static final Duration TEST_GRACE = Duration.ofHours(1);

    private final AppleStore apple;
    private final Supplier<GooglePlay> google;
    private final RbacrGrants grants;
    private final PurchaseStore store;
    private final Clock clock;

    /**
     * @param google null when Google Play isn't configured; a supplier, so
     *               the key file is read only when needed (it may throw)
     */
    StorePurchases(AppleStore apple, Supplier<GooglePlay> google, RbacrGrants grants, PurchaseStore store,
                   Clock clock) {
        this.apple = apple;
        this.google = google;
        this.grants = grants;
        this.store = store;
        this.clock = clock;
    }

    boolean iosEnabled() {
        return grants.configured();
    }

    boolean androidEnabled() {
        return grants.configured() && google != null;
    }

    APIGatewayV2HTTPResponse handle(String route, APIGatewayV2HTTPEvent event) {
        return switch (route) {
            case GET_STORE -> status(event);
            case VERIFY -> verify(event);
            case APPLE_NOTIFICATIONS -> appleNotification(event);
            case JOIN_FREE -> joinFree(event);
            default -> null;
        };
    }

    private APIGatewayV2HTTPResponse status(APIGatewayV2HTTPEvent event) {
        var email = Identity.verifiedEmail(event);
        if (email == null) {
            return response(403, "{\"error\":\"sign in with a verified email\"}");
        }
        var any = iosEnabled() || androidEnabled();
        return response(200, "{\"ios\":" + iosEnabled() + ",\"android\":" + androidEnabled()
                + ",\"accountToken\":" + (any ? Json.string(store.accountToken(email)) : "null") + "}");
    }

    /**
     * Join free (the mobile apps' sign-up sheet, where App Store 3.1.1 and
     * Play's payments policy rule out sending users to subscribe on the
     * web): grants the caller's verified email {@link RbacrGrants#FREE} in
     * the app's system, for good, and nothing else. Idempotent: a caller
     * who holds it already (or a role implying it) gets 200 with {@code
     * "granted": false} and nothing changes. 403 without a verified email,
     * 502 when rbacr fails, 503 without a grant token.
     */
    private APIGatewayV2HTTPResponse joinFree(APIGatewayV2HTTPEvent event) {
        var email = Identity.verifiedEmail(event);
        if (email == null) {
            return response(403, "{\"error\":\"sign in with a verified email\"}");
        }
        if (!grants.configured()) {
            return response(503, "{\"error\":\"joining free is not configured\"}");
        }
        boolean granted;
        try {
            granted = grants.joinFree(email);
        } catch (RbacrGrants.Failed e) {
            System.err.println("presence: joining free failed: " + e.getMessage());
            return response(502, "{\"error\":\"rbacr didn't answer; try again\"}");
        }
        System.out.println("presence: join free " + (granted ? "granted" : "already a member"));
        return response(200, "{\"member\":true,\"granted\":" + granted + "}");
    }

    private APIGatewayV2HTTPResponse verify(APIGatewayV2HTTPEvent event) {
        var email = Identity.verifiedEmail(event);
        if (email == null) {
            return response(403, "{\"error\":\"sign in with a verified email\"}");
        }
        var text = Http.bodyText(event, MAX_VERIFY);
        if (text == null) {
            return response(400, "{\"error\":\"the body is too large\"}");
        }
        String platform;
        String productId;
        String data;
        try {
            var body = JsonReader.object(text);
            platform = JsonReader.string(body, "platform");
            productId = JsonReader.string(body, "productId");
            data = JsonReader.string(body, "verificationData");
        } catch (IllegalArgumentException e) {
            return response(400, "{\"error\":\"send {\\\"platform\\\", \\\"productId\\\", \\\"verificationData\\\"}\"}");
        }
        if (platform == null || productId == null || data == null || data.isBlank()
                || !StorePurchase.PRODUCTS.contains(productId)) {
            return response(400, "{\"error\":\"send a platform (ios or android), a Premium productId"
                    + " and the store's verificationData\"}");
        }
        var ios = StorePurchase.IOS.equals(platform);
        var android = StorePurchase.ANDROID.equals(platform);
        if (!ios && !android) {
            return response(400, "{\"error\":\"platform must be ios or android\"}");
        }
        if (ios ? !iosEnabled() : !androidEnabled()) {
            return response(503, "{\"error\":\"store purchases not configured\"}");
        }
        var now = clock.instant();
        StorePurchase purchase;
        GooglePlay play = null;
        try {
            if (ios) {
                purchase = apple.purchase(data.strip(), now);
                if (!purchase.productId().equals(productId)) {
                    throw new StorePurchase.Invalid("this purchase is " + purchase.productId());
                }
            } else {
                play = google();
                purchase = play.purchase(productId, data.strip());
            }
        } catch (StorePurchase.Invalid e) {
            return response(400, "{\"error\":" + Json.string("the store doesn't vouch for this purchase: "
                    + e.getMessage()) + "}");
        } catch (StorePurchase.Unavailable e) {
            System.err.println("presence: store verification failed: " + e.getMessage());
            return response(502, "{\"error\":\"the store didn't answer; try again\"}");
        }
        // A purchase the app made for another account (its token on it).
        if (purchase.accountToken() != null && !purchase.accountToken().isBlank()
                && !purchase.accountToken().toLowerCase(Locale.ROOT)
                .equals(store.accountToken(email).toLowerCase(Locale.ROOT))) {
            return conflict();
        }
        // Google: an upgrade or resubscription replaces a token another account holds.
        if (purchase.linkedId() != null) {
            var linked = store.binding(PurchaseStore.key(StorePurchase.ANDROID, purchase.linkedId()));
            if (linked.isPresent() && !linked.get().email().equals(email)) {
                return conflict();
            }
        }
        var key = PurchaseStore.key(purchase);
        var bound = store.bind(email, key, purchase.productId(), purchase.expiresAt(), false,
                purchase.signedAt(), now);
        if (!bound.email().equals(email)) {
            return conflict();
        }
        if (bound.stale()) {
            // An older signed state than one recorded (a refund's, say): what's recorded counts.
            var recorded = store.binding(key).orElseThrow();
            if (recorded.revoked() || !recorded.expiresAt().isAfter(now)) {
                return response(400, "{\"error\":\"the store doesn't vouch for this purchase: it has ended"
                        + " since\"}");
            }
        }
        System.out.println("presence: a " + platform + " purchase of " + purchase.productId() + " verified");
        try {
            if (play != null && !purchase.acknowledged()) {
                play.acknowledge(purchase);
            }
        } catch (StorePurchase.Unavailable e) {
            System.err.println("presence: acknowledging failed: " + e.getMessage());
            return response(502, "{\"error\":\"the store didn't answer; try again\"}");
        }
        Instant granted;
        try {
            granted = settle(email, purchase.test());
        } catch (RbacrGrants.Failed e) {
            System.err.println("presence: granting premium failed: " + e.getMessage());
            return response(502, "{\"error\":\"the purchase is verified, but Premium couldn't be granted yet;"
                    + " try again\"}");
        }
        return response(200, "{\"premium\":true,\"platform\":" + Json.string(platform) + ",\"productId\":"
                + Json.string(purchase.productId()) + ",\"expiresAt\":" + purchase.expiresAt().toEpochMilli()
                + ",\"grantedUntil\":" + (granted == null ? "null" : granted.toEpochMilli()) + "}");
    }

    private APIGatewayV2HTTPResponse appleNotification(APIGatewayV2HTTPEvent event) {
        if (!iosEnabled()) {
            return response(503, "{\"error\":\"store purchases not configured\"}");
        }
        var text = Http.bodyText(event, MAX_NOTIFICATION);
        if (text == null) {
            return response(400, "{\"error\":\"the body is too large\"}");
        }
        AppleStore.Notification notification;
        try {
            notification = apple.notification(text);
        } catch (StorePurchase.Invalid e) {
            System.err.println("presence: an App Store notification was refused: " + e.getMessage());
            return response(400, "{\"error\":\"not a notification Apple signed for Presence\"}");
        }
        var transaction = notification.transaction();
        if (transaction == null) {
            return response(200, "{\"handled\":false}");
        }
        var purchase = transaction.purchase();
        var key = PurchaseStore.key(purchase);
        var binding = store.binding(key);
        if (binding.isEmpty()) {
            // Not bound yet: the app binds it when it verifies the purchase.
            return response(200, "{\"handled\":false}");
        }
        var email = binding.get().email();
        var revoked = transaction.revoked() || "REFUND".equals(notification.type())
                || "REVOKE".equals(notification.type());
        var expires = purchase.expiresAt();
        if (notification.graceUntil() != null && notification.graceUntil().isAfter(expires)
                && !AppleStore.ENDS.contains(notification.type())) {
            expires = notification.graceUntil();
        }
        var now = clock.instant();
        if (AppleStore.ENDS.contains(notification.type()) && expires.isAfter(now)) {
            expires = now;
        }
        if (store.bind(email, key, purchase.productId(), expires, revoked, notification.signedAt(), now).stale()) {
            // Apple sent (or someone replayed) an older state than one recorded.
            return response(200, "{\"handled\":false}");
        }
        try {
            settle(email, purchase.test());
        } catch (RbacrGrants.Failed e) {
            // Apple retries a notification that isn't answered 200.
            System.err.println("presence: an App Store notification's grant failed: " + e.getMessage());
            return response(502, "{\"error\":\"rbacr failed\"}");
        }
        System.out.println("presence: App Store notification " + notification.type() + " handled");
        return response(200, "{\"handled\":true}");
    }

    /**
     * Brings {@code email}'s rbacr grant in line with its purchases: until
     * the latest one's end (plus {@link #GRACE}) while one is current, else
     * takes back the grant it made. The end granted, or null.
     */
    Instant settle(String email, boolean test) throws RbacrGrants.Failed {
        var now = clock.instant();
        var latest = store.purchasesOf(email).stream()
                .filter(b -> !b.revoked())
                .map(PurchaseStore.Binding::expiresAt)
                .max(Comparator.naturalOrder())
                .filter(at -> at.isAfter(now));
        if (latest.isPresent()) {
            var granted = grants.extend(email, latest.get().plus(test ? TEST_GRACE : GRACE));
            if (granted != null) {
                store.grantedUntil(email, granted);
            }
            return granted;
        }
        if (grants.end(email, store.grantedUntil(email))) {
            store.grantedUntil(email, null);
        }
        return null;
    }

    private GooglePlay google() throws StorePurchase.Unavailable {
        try {
            return google.get();
        } catch (RuntimeException e) {
            // Never the key itself: only that it couldn't be read.
            System.err.println("presence: the Google Play service account isn't readable: "
                    + e.getClass().getSimpleName());
            throw new StorePurchase.Unavailable("the Google Play service account isn't readable");
        }
    }

    private static APIGatewayV2HTTPResponse conflict() {
        return response(409, "{\"error\":\"this purchase belongs to another Presence account\"}");
    }
}
