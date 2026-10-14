package presence.payments;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.secretsmanager.SecretsManagerClient;

import java.time.Clock;
import java.util.Set;
import java.util.function.Function;
import java.util.function.Supplier;

import static presence.payments.Http.response;

/**
 * The payments API (presence_api_payments): the Stripe Payment Links a
 * free member upgrades to Premium with. Every route is behind the HTTP
 * API's Google JWT authorizer.
 * <ul>
 *   <li>{@code GET /api/payments/links}: the links, {@code {"monthly",
 *       "yearly", "saved"}}: what an admin saved, or the deploy's defaults
 *       ({@code MONTHLY_LINK}, {@code YEARLY_LINK}) until one does.</li>
 *   <li>{@code PUT /api/payments/links} {@code {"monthly", "yearly"}}: an
 *       admin ({@code admin} in rbacr's {@code presence} system, or an
 *       rbacr root) saves them: Stripe HTTPS links, or empty for a plan
 *       that isn't offered. 403 for anyone else, 400 for links that aren't
 *       Stripe's.</li>
 *   <li>{@code /api/payments/store/*}: Premium bought in the App Store or
 *       Google Play ({@link StorePurchases}).</li>
 * </ul>
 * Who pays through Stripe (the web) becomes premium in rbacr, which syncs
 * the Stripe account's subscriptions: this API never sees those payments.
 * Store purchases it verifies with the store, and grants {@code premium}
 * in rbacr itself.
 */
public class PaymentsHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    static final String GET_LINKS = "GET /api/payments/links";
    static final String PUT_LINKS = "PUT /api/payments/links";

    /** rbacr roles (in the presence system, or global for {@link Rbacr#ROOT}) that may save links. */
    static final Set<String> ADMINS = Set.of("admin", Rbacr.ROOT);

    private final LinkStore store;
    private final PaymentLinks defaults;
    private final Function<String, Set<String>> rbacr;
    private final Clock clock;
    private final StorePurchases purchases;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public PaymentsHandler() {
        this(LinkStore.dynamo(System.getenv("PAYMENTS_TABLE")),
                PaymentLinks.defaults(System.getenv("MONTHLY_LINK"), System.getenv("YEARLY_LINK")),
                Rbacr.fromEnvironment(), Clock.systemUTC(), storeFromEnvironment());
    }

    PaymentsHandler(LinkStore store, PaymentLinks defaults, Function<String, Set<String>> rbacr, Clock clock,
                    StorePurchases purchases) {
        this.store = store;
        this.defaults = defaults;
        this.rbacr = rbacr;
        this.clock = clock;
        this.purchases = purchases;
    }

    /**
     * Store purchases from the environment: {@code STORE_ALLOW_SANDBOX}
     * ({@code true}: App Store sandbox and Google Play test purchases
     * count), {@code GOOGLE_PLAY_SECRET} (the Secrets Manager secret
     * holding the Google service account's key file; empty: no Google
     * Play) and {@code RBACR_GRANT_TOKEN} (empty: neither store).
     */
    static StorePurchases storeFromEnvironment() {
        var allowSandbox = "true".equals(System.getenv("STORE_ALLOW_SANDBOX"));
        var web = Web.jdk();
        var secret = System.getenv().getOrDefault("GOOGLE_PLAY_SECRET", "").strip();
        Supplier<GooglePlay> google = secret.isEmpty() ? null : new Supplier<>() {
            private GooglePlay play;

            @Override
            public synchronized GooglePlay get() {
                if (play == null) {
                    // Read once per instance, when an Android purchase first needs it.
                    try (var secrets = SecretsManagerClient.builder()
                            .httpClient(UrlConnectionHttpClient.create()).build()) {
                        var keyFile = secrets.getSecretValue(r -> r.secretId(secret)).secretString();
                        play = GooglePlay.fromKeyFile(keyFile, web, Clock.systemUTC(), allowSandbox);
                    }
                }
                return play;
            }
        };
        return new StorePurchases(new AppleStore(AppleJws.apple(), allowSandbox), google,
                RbacrGrants.fromEnvironment(web), PurchaseStore.dynamo(System.getenv("PAYMENTS_TABLE")),
                Clock.systemUTC());
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        // Only through the site (CloudFront), never the API's own host.
        if (!OriginCheck.fromEnvironment().allows(event)) {
            return OriginCheck.refused();
        }
        var route = Http.route(event);
        try {
            return switch (route) {
                case GET_LINKS -> response(200, store.load().orElse(defaults).toJson());
                case PUT_LINKS -> save(event);
                default -> {
                    var answer = purchases == null ? null : purchases.handle(route, event);
                    yield answer != null ? answer : response(404, "{\"error\":\"no such route\"}");
                }
            };
        } catch (RuntimeException e) {
            var requestId = context == null ? null : context.getAwsRequestId();
            System.err.println("presence: " + route + " failed (request " + requestId + "): " + e);
            return response(502, "{\"error\":\"the payments store failed\""
                    + (requestId == null ? "" : ",\"requestId\":" + Json.string(requestId)) + "}");
        }
    }

    private APIGatewayV2HTTPResponse save(APIGatewayV2HTTPEvent event) {
        var email = Identity.verifiedEmail(event);
        if (email == null || rbacr.apply(email).stream().noneMatch(ADMINS::contains)) {
            return response(403, "{\"error\":\"only an admin may change the payment links\"}");
        }
        var body = PaymentLinks.parse(Http.bodyText(event, 2048));
        if (body == null) {
            return response(400, "{\"error\":\"send {\\\"monthly\\\": \\\"...\\\", \\\"yearly\\\": \\\"...\\\"}\"}");
        }
        var monthly = body.get("monthly").strip();
        var yearly = body.get("yearly").strip();
        if (!PaymentLinks.valid(monthly) || !PaymentLinks.valid(yearly)) {
            return response(400, "{\"error\":\"each link must be empty or an https link on stripe.com\"}");
        }
        var links = new PaymentLinks(monthly, yearly, clock.millis(), email);
        store.save(links);
        System.out.println("presence: payment links saved by an admin");
        return response(200, links.toJson());
    }
}
