package presence.payments;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.Signature;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.util.Base64;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * Google Play's side of store purchases: a subscription's purchase token,
 * looked up with the Android Publisher API ({@code
 * purchases.subscriptionsv2.get}) as a service account that Play Console
 * gave access to the app, and acknowledged server-side once it's bound to
 * an account. The service account's key (its JSON key file) comes from
 * Secrets Manager; it's never logged.
 */
final class GooglePlay {

    /** Google's OAuth token endpoint, the only one used (whatever the key file says). */
    static final URI TOKEN_URI = URI.create("https://oauth2.googleapis.com/token");

    static final String SCOPE = "https://www.googleapis.com/auth/androidpublisher";

    static final String API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
            + StorePurchase.APP_ID + "/purchases/";

    /** A purchase token: URL-safe characters only, so it goes into a path as it is. */
    static final Pattern TOKEN = Pattern.compile("[A-Za-z0-9._-]{16,2048}");

    /** The states in which a subscription gives Premium. */
    static final Set<String> ENTITLED = Set.of("SUBSCRIPTION_STATE_ACTIVE", "SUBSCRIPTION_STATE_IN_GRACE_PERIOD");

    private final String clientEmail;
    private final PrivateKey key;
    private final Web web;
    private final Clock clock;
    private final boolean allowTest;
    private String accessToken;
    private Instant accessTokenUntil = Instant.EPOCH;

    GooglePlay(String clientEmail, PrivateKey key, Web web, Clock clock, boolean allowTest) {
        this.clientEmail = clientEmail;
        this.key = key;
        this.web = web;
        this.clock = clock;
        this.allowTest = allowTest;
    }

    /**
     * From a service account's JSON key file ({@code client_email}, {@code
     * private_key}); throws when it isn't one. {@code allowTest} takes
     * license testers' purchases (the RC).
     */
    static GooglePlay fromKeyFile(String json, Web web, Clock clock, boolean allowTest) {
        var file = JsonReader.object(json);
        var email = JsonReader.string(file, "client_email");
        var pem = JsonReader.string(file, "private_key");
        if (email == null || pem == null || !"service_account".equals(JsonReader.string(file, "type"))) {
            throw new IllegalArgumentException("not a service account key file");
        }
        var der = Base64.getMimeDecoder().decode(pem
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", ""));
        try {
            var key = KeyFactory.getInstance("RSA").generatePrivate(new PKCS8EncodedKeySpec(der));
            return new GooglePlay(email, key, web, clock, allowTest);
        } catch (GeneralSecurityException e) {
            throw new IllegalArgumentException("the service account's key doesn't load");
        }
    }

    /** The subscription behind {@code purchaseToken}: Presence's {@code productId}, entitled now. */
    StorePurchase purchase(String productId, String purchaseToken)
            throws StorePurchase.Invalid, StorePurchase.Unavailable {
        if (purchaseToken == null || !TOKEN.matcher(purchaseToken).matches()) {
            throw new StorePurchase.Invalid("not a purchase token");
        }
        var reply = call("GET", URI.create(API + "subscriptionsv2/tokens/" + purchaseToken), null);
        if (reply.status() == 400 || reply.status() == 404 || reply.status() == 410) {
            throw new StorePurchase.Invalid("Google Play doesn't know this purchase");
        }
        if (reply.status() != 200) {
            throw new StorePurchase.Unavailable("Google Play answered " + reply.status());
        }
        Map<String, Object> subscription;
        try {
            subscription = JsonReader.object(reply.body());
        } catch (IllegalArgumentException e) {
            throw new StorePurchase.Unavailable("Google Play's answer isn't JSON");
        }
        var test = subscription.get("testPurchase") != null;
        if (test && !allowTest) {
            throw new StorePurchase.Invalid("a test purchase isn't taken here");
        }
        var state = JsonReader.string(subscription, "subscriptionState");
        if (!ENTITLED.contains(state)) {
            throw new StorePurchase.Invalid("this subscription isn't active (" + state + ")");
        }
        Instant expires = null;
        for (var item : JsonReader.list(subscription, "lineItems")) {
            @SuppressWarnings("unchecked")
            var line = item instanceof Map<?, ?> m ? (Map<String, Object>) m : null;
            if (productId.equals(JsonReader.string(line, "productId"))) {
                try {
                    var at = Instant.parse(JsonReader.string(line, "expiryTime"));
                    expires = expires == null || at.isAfter(expires) ? at : expires;
                } catch (DateTimeParseException | NullPointerException e) {
                    throw new StorePurchase.Unavailable("Google Play's expiry isn't a time");
                }
            }
        }
        if (expires == null) {
            throw new StorePurchase.Invalid("this purchase isn't " + productId);
        }
        if (!expires.isAfter(clock.instant())) {
            throw new StorePurchase.Invalid("this subscription has expired");
        }
        var linked = JsonReader.string(subscription, "linkedPurchaseToken");
        var account = JsonReader.string(JsonReader.child(subscription, "externalAccountIdentifiers"),
                "obfuscatedExternalAccountId");
        var acknowledged = "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED".equals(
                JsonReader.string(subscription, "acknowledgementState"));
        return new StorePurchase(StorePurchase.ANDROID, purchaseToken,
                linked != null && TOKEN.matcher(linked).matches() ? linked : null,
                productId, expires, account, test, acknowledged, clock.instant());
    }

    /** Acknowledges {@code purchase} (else Google refunds it after three days). */
    void acknowledge(StorePurchase purchase) throws StorePurchase.Unavailable {
        var reply = call("POST", URI.create(API + "subscriptions/" + purchase.productId() + "/tokens/"
                + purchase.purchaseId() + ":acknowledge"), "{}");
        if (reply.status() / 100 != 2) {
            throw new StorePurchase.Unavailable("Google Play didn't take the acknowledgement: " + reply.status());
        }
    }

    private Web.Reply call(String method, URI uri, String body) throws StorePurchase.Unavailable {
        try {
            var headers = body == null
                    ? Map.of("authorization", "Bearer " + accessToken())
                    : Map.of("authorization", "Bearer " + accessToken(), "content-type", "application/json");
            return web.send(method, uri, headers, body);
        } catch (StorePurchase.Unavailable e) {
            throw e;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new StorePurchase.Unavailable("interrupted");
        } catch (Exception e) {
            throw new StorePurchase.Unavailable("Google Play didn't answer: " + e.getClass().getSimpleName());
        }
    }

    /** An access token for the Android Publisher API, reused until a minute before it ends. */
    synchronized String accessToken() throws Exception {
        var now = clock.instant();
        if (accessToken != null && now.isBefore(accessTokenUntil)) {
            return accessToken;
        }
        var b64 = Base64.getUrlEncoder().withoutPadding();
        var header = b64.encodeToString("{\"alg\":\"RS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));
        var claims = b64.encodeToString(("{\"iss\":" + Json.string(clientEmail) + ",\"scope\":\"" + SCOPE
                + "\",\"aud\":\"" + TOKEN_URI + "\",\"iat\":" + now.getEpochSecond()
                + ",\"exp\":" + now.plus(Duration.ofHours(1)).getEpochSecond() + "}")
                .getBytes(StandardCharsets.UTF_8));
        var signer = Signature.getInstance("SHA256withRSA");
        signer.initSign(key);
        signer.update((header + "." + claims).getBytes(StandardCharsets.US_ASCII));
        var assertion = header + "." + claims + "." + b64.encodeToString(signer.sign());
        var reply = web.send("POST", TOKEN_URI, Map.of("content-type", "application/x-www-form-urlencoded"),
                "grant_type=" + URLEncoder.encode("urn:ietf:params:oauth:grant-type:jwt-bearer", StandardCharsets.UTF_8)
                        + "&assertion=" + assertion);
        if (reply.status() != 200) {
            throw new StorePurchase.Unavailable("Google refused the service account: " + reply.status());
        }
        var answer = JsonReader.object(reply.body());
        var token = JsonReader.string(answer, "access_token");
        var seconds = JsonReader.number(answer, "expires_in");
        if (token == null) {
            throw new StorePurchase.Unavailable("Google's token answer has no token");
        }
        accessToken = token;
        accessTokenUntil = now.plusSeconds(Math.max(0, (seconds == null ? 3600 : seconds) - 60));
        return token;
    }
}
