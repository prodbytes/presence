package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.core.client.config.ClientOverrideConfiguration;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.cognitoidentity.CognitoIdentityClient;
import software.amazon.awssdk.services.cognitoidentity.model.DescribeIdentityPoolRequest;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;
import software.amazon.awssdk.services.dynamodb.model.DescribeTableRequest;
import software.amazon.awssdk.services.dynamodb.model.TableStatus;
import software.amazon.awssdk.services.s3.S3Client;
import software.amazon.awssdk.services.s3.model.HeadBucketRequest;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import static presence.auth.Http.response;

/**
 * {@code GET /health} (public, no token): whether everything the API needs
 * works, for the site's Route 53 health check (presence_infra/site.yaml).
 * Each {@link Check} runs at once, in parallel, within {@link #BUDGET}:
 * <ul>
 *   <li>{@code settings}: an OIDC client (RBAC mode), the identity pool and
 *       the user-data bucket are configured ({@link Settings});</li>
 *   <li>{@code dynamodb}: every table is ACTIVE;</li>
 *   <li>{@code s3}: the user-data bucket answers;</li>
 *   <li>{@code cognito}: the identity pool answers;</li>
 *   <li>{@code google}: Google's token signing keys load (the JWT
 *       authorizer needs them);</li>
 *   <li>{@code rbacr}: rbacr, which says who's premium ({@link Rbacr}),
 *       answers its health check; only when it's configured
 *       ({@code RBACR_URL}, set with a token). Without it, nobody syncs with the cloud.</li>
 * </ul>
 * 200 {@code {"status":"ok","checks":{"settings":"ok",...},"version":"0.6.…"}}
 * when all pass, else 503 with {@code "status":"fail"} and the failing checks
 * as {@code "fail"}. {@code version} is the release deployed
 * ({@code PRESENCE_VERSION}), left out when unset, so anyone can see when a
 * release is live. Only names and ok/fail are public; why a check failed goes
 * to the function's log. A result is reused for {@link #CACHE_FOR}, so Route
 * 53's checkers don't each call every service.
 */
public class HealthHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** How long a result is reused. */
    static final Duration CACHE_FOR = Duration.ofSeconds(20);

    /** How long the checks may take together: Route 53 wants an answer within 2 s. */
    static final Duration BUDGET = Duration.ofMillis(1500);

    /** Google's token signing keys, which the HTTP API's JWT authorizer fetches. */
    static final URI GOOGLE_KEYS = URI.create("https://www.googleapis.com/oauth2/v3/certs");

    /** A named probe: returns if healthy, throws why not otherwise. */
    record Check(String name, Probe probe) {
    }

    @FunctionalInterface
    interface Probe {
        void run() throws Exception;
    }

    private final List<Check> checks;
    private final Clock clock;
    private final Duration budget;
    private final String version;
    private APIGatewayV2HTTPResponse last;
    private Instant lastAt;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public HealthHandler() {
        this(fromEnvironment(), Clock.systemUTC(), BUDGET, System.getenv("PRESENCE_VERSION"));
    }

    HealthHandler(List<Check> checks, Clock clock, Duration budget) {
        this(checks, clock, budget, null);
    }

    HealthHandler(List<Check> checks, Clock clock, Duration budget, String version) {
        this.checks = checks;
        this.clock = clock;
        this.budget = budget;
        this.version = version == null || version.isBlank() ? null : version.strip();
    }

    @Override
    public synchronized APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var now = clock.instant();
        if (last != null && now.isBefore(lastAt.plus(CACHE_FOR))) {
            return last;
        }
        var results = run(context);
        var healthy = results.values().stream().allMatch(ok -> ok);
        var json = new StringBuilder("{\"status\":\"").append(healthy ? "ok" : "fail").append("\",\"checks\":{");
        var first = true;
        for (var result : results.entrySet()) {
            json.append(first ? "" : ",").append(Json.string(result.getKey())).append(':')
                    .append(result.getValue() ? "\"ok\"" : "\"fail\"");
            first = false;
        }
        json.append('}');
        if (version != null) {
            json.append(",\"version\":").append(Json.string(version));
        }
        json.append('}');
        last = response(healthy ? 200 : 503, json.toString());
        lastAt = now;
        return last;
    }

    /** Each check's name and whether it passed, in order; one past the budget fails. */
    private Map<String, Boolean> run(Context context) {
        var results = new LinkedHashMap<String, Boolean>();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var futures = new ArrayList<Future<?>>();
            for (var check : checks) {
                futures.add(executor.submit(() -> {
                    check.probe().run();
                    return null;
                }));
            }
            var deadline = System.nanoTime() + budget.toNanos();
            for (var i = 0; i < checks.size(); i++) {
                var name = checks.get(i).name();
                try {
                    futures.get(i).get(Math.max(0, deadline - System.nanoTime()), TimeUnit.NANOSECONDS);
                    results.put(name, true);
                } catch (TimeoutException e) {
                    futures.get(i).cancel(true);
                    log(context, name + ": no answer within " + budget.toMillis() + " ms");
                    results.put(name, false);
                } catch (ExecutionException e) {
                    log(context, name + ": " + e.getCause());
                    results.put(name, false);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    results.put(name, false);
                }
            }
            executor.shutdownNow();
        }
        return results;
    }

    private static void log(Context context, String message) {
        if (context != null && context.getLogger() != null) {
            context.getLogger().log("health check failed: " + message + "\n");
        }
    }

    /** The checks against this stack's resources, named in the environment (see template.yaml). */
    static List<Check> fromEnvironment() {
        var settings = Settings.fromEnvironment();
        var pool = System.getenv("COGNITO_IDENTITY_POOL_ID");
        var bucket = System.getenv("USER_DATA_BUCKET");
        var tables = Arrays.stream(System.getenv().getOrDefault("HEALTH_TABLES", "").split(","))
                .map(String::strip).filter(t -> !t.isEmpty()).toList();
        // Made here, in Lambda's init phase, so a check only pays for its call.
        var overrides = ClientOverrideConfiguration.builder().apiCallTimeout(BUDGET).build();
        var dynamo = DynamoDbClient.builder().httpClient(UrlConnectionHttpClient.create())
                .overrideConfiguration(overrides).build();
        var s3 = S3Client.builder().httpClient(UrlConnectionHttpClient.create())
                .overrideConfiguration(overrides).build();
        var cognito = CognitoIdentityClient.builder().httpClient(UrlConnectionHttpClient.create())
                .overrideConfiguration(overrides).build();
        var http = HttpClient.newBuilder().connectTimeout(BUDGET).build();
        var checks = new ArrayList<>(List.of(
                new Check("settings", () -> {
                    if (!settings.oidc() || !settings.aws()) {
                        throw new IllegalStateException("settings " + settings.toJson() + " aren't all set");
                    }
                }),
                new Check("dynamodb", () -> {
                    if (tables.isEmpty()) {
                        throw new IllegalStateException("HEALTH_TABLES is empty");
                    }
                    for (var table : tables) {
                        var status = dynamo.describeTable(DescribeTableRequest.builder().tableName(table).build())
                                .table().tableStatus();
                        if (status != TableStatus.ACTIVE) {
                            throw new IllegalStateException(table + " is " + status);
                        }
                    }
                }),
                new Check("s3", () -> s3.headBucket(HeadBucketRequest.builder().bucket(bucket).build())),
                new Check("cognito", () -> cognito.describeIdentityPool(
                        DescribeIdentityPoolRequest.builder().identityPoolId(pool).build())),
                new Check("google", () -> {
                    var status = http.send(HttpRequest.newBuilder(GOOGLE_KEYS).timeout(BUDGET).GET().build(),
                            HttpResponse.BodyHandlers.discarding()).statusCode();
                    if (status != 200) {
                        throw new IllegalStateException(GOOGLE_KEYS + " answered " + status);
                    }
                })));
        // Set only where rbacr is (template.yaml): its token stays out of here.
        var rbacrUrl = System.getenv("RBACR_URL");
        if (rbacrUrl != null && !rbacrUrl.isBlank()) {
            var rbacr = URI.create(rbacrUrl.strip()).resolve("/health");
            checks.add(new Check("rbacr", () -> {
                var status = http.send(HttpRequest.newBuilder(rbacr).timeout(BUDGET).GET().build(),
                        HttpResponse.BodyHandlers.discarding()).statusCode();
                if (status != 200) {
                    throw new IllegalStateException(rbacr + " answered " + status);
                }
            }));
        }
        return List.copyOf(checks);
    }
}
