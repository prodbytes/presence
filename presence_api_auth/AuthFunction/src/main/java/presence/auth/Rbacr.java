package presence.auth;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Function;
import java.util.regex.Pattern;

/**
 * The roles <a href="https://github.com/prodbytes/rbacr">rbacr</a> gives an
 * email in the {@code presence} system ({@code free}, {@code premium},
 * {@code admin}, …), asked server-side with an API token ({@code POST
 * /api/roles}). rbacr answers effective roles: grants to the address and
 * its domain, global grants and implied roles.
 *
 * <p>It fails closed: when rbacr can't answer (down, slow, refusing the
 * token, an answer that isn't one), the email has no rbacr roles, as rbacr
 * asks of its clients. Answers are reused for {@link #CACHE_FOR} (rbacr
 * suggests a minute or less), errors never.
 */
final class Rbacr implements Function<String, Set<String>> {

    /** How long an answer is reused. */
    static final Duration CACHE_FOR = Duration.ofSeconds(60);

    /** How long rbacr may take: a sign-in or credentials request waits for it. */
    static final Duration TIMEOUT = Duration.ofSeconds(2);

    /** The system the app's roles are in. */
    static final String SYSTEM = "presence";

    private static final Pattern ROLES = Pattern.compile("\"roles\"\\s*:\\s*\\[([^\\]]*)\\]");
    private static final Pattern ROLE = Pattern.compile("\"([a-z0-9][a-z0-9_.-]{0,63})\"");

    private final URI base;
    private final String token;
    private final String system;
    private final Transport transport;
    private final Clock clock;
    private final Map<String, Answer> cache = new ConcurrentHashMap<>();

    private record Answer(Set<String> roles, Instant at) {
    }

    /** Sends a request body to rbacr's {@code /api/roles} and returns the status and body. */
    @FunctionalInterface
    interface Transport {
        Reply post(URI uri, String token, String body) throws Exception;
    }

    record Reply(int status, String body) {
    }

    Rbacr(URI base, String token, String system, Transport transport, Clock clock) {
        this.base = base;
        this.token = token;
        this.system = system;
        this.transport = transport;
        this.clock = clock;
    }

    /**
     * From the function's environment ({@code RBACR_URL}, {@code
     * RBACR_TOKEN}; see template.yaml): without a token, nobody has rbacr
     * roles.
     */
    static Function<String, Set<String>> fromEnvironment() {
        var token = System.getenv("RBACR_TOKEN");
        if (token == null || token.isBlank()) {
            return email -> Set.of();
        }
        var url = System.getenv().getOrDefault("RBACR_URL", "https://rbacr.nu01.com");
        return new Rbacr(URI.create(url.strip()), token.strip(), SYSTEM, http(), Clock.systemUTC());
    }

    /** The JDK's HTTP client, within {@link #TIMEOUT}. */
    static Transport http() {
        var client = HttpClient.newBuilder().connectTimeout(TIMEOUT).build();
        return (uri, token, body) -> {
            var response = client.send(HttpRequest.newBuilder(uri)
                            .timeout(TIMEOUT)
                            .header("authorization", "Bearer " + token)
                            .header("content-type", "application/json")
                            .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                            .build(),
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            return new Reply(response.statusCode(), response.body());
        };
    }

    @Override
    public Set<String> apply(String email) {
        var normalized = email.trim().toLowerCase(Locale.ROOT);
        var now = clock.instant();
        var cached = cache.get(normalized);
        if (cached != null && now.isBefore(cached.at().plus(CACHE_FOR))) {
            return cached.roles();
        }
        try {
            var reply = transport.post(base.resolve("/api/roles"), token,
                    "{\"email\":" + Json.string(normalized) + ",\"systemId\":" + Json.string(system) + "}");
            var roles = reply.status() == 200 ? roles(reply.body()) : null;
            if (roles == null) {
                System.err.println("rbacr: no roles for an email: HTTP " + reply.status());
                return Set.of();
            }
            cache.put(normalized, new Answer(roles, now));
            return roles;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return Set.of();
        } catch (Exception e) {
            // Down or slow: nobody gets what it would give (fail closed).
            System.err.println("rbacr: no answer: " + e);
            return Set.of();
        }
    }

    /** The roles in an answer of {@code /api/roles}; null when it isn't one. */
    static Set<String> roles(String body) {
        if (body == null) {
            return null;
        }
        var list = ROLES.matcher(body);
        if (!list.find()) {
            return null;
        }
        var roles = new TreeSet<String>();
        var items = list.group(1).strip();
        if (items.isEmpty()) {
            return roles;
        }
        for (var item : items.split(",")) {
            var role = ROLE.matcher(item.strip());
            if (!role.matches()) {
                return null;
            }
            roles.add(role.group(1));
        }
        return roles;
    }
}
