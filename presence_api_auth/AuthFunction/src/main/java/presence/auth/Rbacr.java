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
 * <a href="https://github.com/prodbytes/rbacr">rbacr</a>, which decides
 * every role: who may use the app, administer it and sync with the cloud.
 * Asked server-side with an API token, which must be an rbacr root's, since
 * it asks about other people: {@link #apply} answers an email's roles in
 * the app's system ({@code free}, {@code premium}, {@code admin}, …), plus
 * {@link #ROOT} when rbacr says the email is a root ({@code POST /api/roles}
 * without a {@code systemId}: one request answers both). rbacr answers
 * effective roles: grants valid now to the address and its domain, global
 * grants, implied roles, and every role for its roots. {@code root} can't
 * be a role in an rbacr system, so the two never mix up.
 *
 * <p>It fails closed: when rbacr can't answer (down, slow, refusing the
 * token, an answer that isn't one), the email has no roles, as rbacr asks
 * of its clients. Answers are reused for {@link #CACHE_FOR} (rbacr suggests
 * a minute or less), errors never.
 */
final class Rbacr implements Function<String, Set<String>> {

    /** How long an answer is reused. */
    static final Duration CACHE_FOR = Duration.ofSeconds(60);

    /** How long rbacr may take: a sign-in or credentials request waits for it. */
    static final Duration TIMEOUT = Duration.ofSeconds(2);

    /** The system the app's roles are in, unless {@code RBACR_SYSTEM} names another. */
    static final String SYSTEM = "presence";

    /** rbacr's global role for its roots, added to their roles by {@link #apply}. */
    static final String ROOT = "root";

    private static final String NAME = "\"([a-z0-9][a-z0-9_.:-]{0,62})\"";
    private static final Pattern GLOBAL_ROLES = Pattern.compile("\"globalRoles\"\\s*:\\s*\\[([^\\]]*)\\]");
    private static final Pattern ROLE_MAP = Pattern.compile("\"roles\"\\s*:\\s*\\{([^}]*)\\}");
    private static final Pattern ENTRY = Pattern.compile("\\s*" + NAME + "\\s*:\\s*\\[([^\\]]*)\\]\\s*(,|$)");
    private static final Pattern ROLE = Pattern.compile(NAME);

    private final URI base;
    private final String token;
    private final String system;
    private final Transport transport;
    private final Clock clock;
    private final Map<String, Answer> cache = new ConcurrentHashMap<>();

    private record Answer(Set<String> roles, Instant at) {
    }

    /** POSTs a JSON body to rbacr and returns the status and body. */
    @FunctionalInterface
    interface Transport {
        Reply post(URI uri, String token, String body) throws Exception;
    }

    record Reply(int status, String body) {
    }

    /** @param token null when rbacr isn't configured: nobody has roles */
    Rbacr(URI base, String token, String system, Transport transport, Clock clock) {
        this.base = base;
        this.token = token;
        this.system = system;
        this.transport = transport;
        this.clock = clock;
    }

    private static Rbacr environment;

    /**
     * From the function's environment ({@code RBACR_URL}, {@code
     * RBACR_TOKEN}, {@code RBACR_SYSTEM}; see template.yaml), one per
     * function, so its cache is shared. Without a token, nobody has roles.
     */
    static synchronized Rbacr fromEnvironment() {
        if (environment == null) {
            var token = System.getenv("RBACR_TOKEN");
            var url = System.getenv().getOrDefault("RBACR_URL", "");
            var system = System.getenv().getOrDefault("RBACR_SYSTEM", "");
            environment = new Rbacr(URI.create(url.isBlank() ? "https://rbacr.nu01.com" : url.strip()),
                    token == null || token.isBlank() ? null : token.strip(),
                    system.isBlank() ? SYSTEM : system.strip(), http(), Clock.systemUTC());
        }
        return environment;
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

    /** The email's roles in the system, plus {@link #ROOT} for an rbacr root; empty when rbacr can't say. */
    @Override
    public Set<String> apply(String email) {
        if (token == null) {
            return Set.of();
        }
        var normalized = normalize(email);
        var now = clock.instant();
        var cached = cache.get(normalized);
        if (cached != null && now.isBefore(cached.at().plus(CACHE_FOR))) {
            return cached.roles();
        }
        try {
            var reply = transport.post(base.resolve("/api/roles"), token,
                    "{\"email\":" + Json.string(normalized) + "}");
            var roles = reply.status() == 200 ? roles(reply.body(), system) : null;
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

    private static String normalize(String email) {
        return email.trim().toLowerCase(Locale.ROOT);
    }

    /**
     * The roles in an answer of {@code /api/roles} without a {@code
     * systemId}, {@code {"globalRoles": [...], "roles": {"<system>": [...]}}}:
     * {@code system}'s (none when it isn't listed), plus {@link #ROOT} when
     * {@code globalRoles} has it; null when it isn't one.
     */
    static Set<String> roles(String body, String system) {
        if (body == null) {
            return null;
        }
        var global = GLOBAL_ROLES.matcher(body);
        var map = ROLE_MAP.matcher(body);
        if (!global.find() || !map.find()) {
            return null;
        }
        var globalRoles = list(global.group(1));
        if (globalRoles == null) {
            return null;
        }
        var roles = new TreeSet<String>();
        var entries = map.group(1);
        var entry = ENTRY.matcher(entries);
        var at = 0;
        while (at < entries.length() && !entries.substring(at).isBlank()) {
            if (!entry.find(at) || entry.start() != at) {
                return null;
            }
            var items = list(entry.group(2));
            if (items == null) {
                return null;
            }
            if (entry.group(1).equals(system)) {
                roles.addAll(items);
            }
            at = entry.end();
        }
        // Reserved in rbacr, so never a system's role: only globalRoles gives it.
        roles.remove(ROOT);
        if (globalRoles.contains(ROOT)) {
            roles.add(ROOT);
        }
        return roles;
    }

    /** The names in a JSON list's items ({@code "a", "b"}); null if one isn't a role name. */
    private static Set<String> list(String items) {
        var roles = new TreeSet<String>();
        if (items.isBlank()) {
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
