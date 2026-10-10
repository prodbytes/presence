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
 * it asks about other people and grants roles:
 * <ul>
 *   <li>{@link #apply}: an email's roles in the app's system ({@code
 *       free}, {@code premium}, {@code admin}, …), plus {@link #ROOT} when
 *       rbacr says the email is a root ({@code POST /api/roles} without a
 *       {@code systemId}: one request answers both). rbacr answers
 *       effective roles: grants valid now to the address and its domain,
 *       global grants, implied roles, and every role for its roots. {@code
 *       root} can't be a role in an rbacr system, so the two never mix up;</li>
 *   <li>{@link #grant}: gives an email a role in the system, for good
 *       ({@code POST /api/systems/:id/grants});</li>
 *   <li>{@link #maintenance}: whether the system is in maintenance: rbacr
 *       must pass its health check ({@code GET /health}, as {@link
 *       HealthHandler}'s {@code rbacr} check), and then its system's flag
 *       (rbacr's R11, {@code GET /api/systems/:id}) says; and
 *       {@link #setMaintenance} switches it ({@code PATCH}). While it's
 *       on, rbacr gives nobody a role in the system; roots keep their
 *       global {@link #ROOT}.</li>
 * </ul>
 *
 * <p>It fails closed: when rbacr can't answer (down, slow, refusing the
 * token, an answer that isn't one), the email has no roles, as rbacr asks
 * of its clients. Answers are reused for {@link #CACHE_FOR} (rbacr suggests
 * a minute or less), errors never; a grant forgets the email's answer.
 */
final class Rbacr implements Function<String, Set<String>> {

    /** How long an answer is reused. */
    static final Duration CACHE_FOR = Duration.ofSeconds(60);

    /**
     * How long the system's maintenance flag is reused, answered or not:
     * every app start asks it, and an admin's switch reaches every
     * function instance within it.
     */
    static final Duration MODE_CACHE_FOR = Duration.ofSeconds(10);

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
    private static final Pattern MAINTENANCE = Pattern.compile("\"maintenance\"\\s*:\\s*(true|false)");

    private final URI base;
    private final String token;
    private final String system;
    private final Transport transport;
    private final Clock clock;
    private final Map<String, Answer> cache = new ConcurrentHashMap<>();

    private record Answer(Set<String> roles, Instant at) {
    }

    /** The maintenance flag, null when rbacr couldn't say, and when it was asked. */
    private record Mode(Boolean maintenance, Instant at) {
    }

    private volatile Mode mode;

    /** Sends a request ({@code GET}: no body; else a JSON body) to rbacr and returns the status and body. */
    @FunctionalInterface
    interface Transport {
        Reply send(String method, URI uri, String token, String body) throws Exception;
    }

    record Reply(int status, String body) {
    }

    /** @param token null when rbacr isn't configured: nobody has roles, and grants fail */
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
        return (method, uri, token, body) -> {
            var request = HttpRequest.newBuilder(uri).timeout(TIMEOUT);
            // Not to its public health check.
            if (token != null) {
                request.header("authorization", "Bearer " + token);
            }
            if (body == null) {
                request.method(method, HttpRequest.BodyPublishers.noBody());
            } else {
                request.header("content-type", "application/json")
                        .method(method, HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));
            }
            var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
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
            var reply = transport.send("POST", base.resolve("/api/roles"), token,
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

    /**
     * Grants {@code role} in the system to {@code email}, from now on and
     * for good. rbacr keeps an existing grant that already does (G2).
     *
     * @throws IllegalStateException when rbacr isn't configured or doesn't grant it
     */
    void grant(String email, String role) {
        if (token == null) {
            throw new IllegalStateException("rbacr isn't configured (RBACR_TOKEN)");
        }
        var normalized = normalize(email);
        Reply reply;
        try {
            reply = transport.send("POST", base.resolve("/api/systems/" + system + "/grants"), token,
                    "{\"role\":" + Json.string(role) + ",\"grantee\":" + Json.string(normalized) + "}");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("interrupted granting a role in rbacr", e);
        } catch (Exception e) {
            throw new IllegalStateException("rbacr didn't answer a grant", e);
        } finally {
            // The old answer (without the role) mustn't outlive the grant.
            cache.remove(normalized);
        }
        if (reply.status() != 201) {
            throw new IllegalStateException("rbacr refused a grant of " + role + ": HTTP " + reply.status());
        }
    }

    /**
     * Whether rbacr has the system in maintenance: {@code true} or {@code
     * false}, or null when it can't say: not configured, failing its health
     * check ({@code GET /health} not 200: down, slow, unhealthy), or
     * then not answering the flag (refusing the token, an answer that isn't
     * the system). Reused for
     * {@link #MODE_CACHE_FOR}, null answers too, so a down rbacr isn't
     * waited for at every app start.
     */
    Boolean maintenance() {
        if (token == null) {
            return null;
        }
        var now = clock.instant();
        var cached = mode;
        if (cached != null && now.isBefore(cached.at().plus(MODE_CACHE_FOR))) {
            return cached.maintenance();
        }
        Boolean answer = null;
        try {
            var health = transport.send("GET", base.resolve("/health"), null, null);
            if (health.status() != 200) {
                System.err.println("rbacr: health check failed (HTTP " + health.status() + "): maintenance");
                mode = new Mode(null, now);
                return null;
            }
            var reply = transport.send("GET", base.resolve("/api/systems/" + system), token, null);
            answer = reply.status() == 200 ? maintenance(reply.body(), system) : null;
            if (answer == null) {
                System.err.println("rbacr: no maintenance flag for the system: HTTP " + reply.status());
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (Exception e) {
            System.err.println("rbacr: no answer about maintenance (its health check or flag): " + e);
        }
        mode = new Mode(answer, now);
        return answer;
    }

    /**
     * Puts the system in maintenance, or ends it ({@code PATCH
     * /api/systems/:id {"maintenance": on}}; only a root's token may).
     *
     * @throws IllegalStateException when rbacr isn't configured or doesn't switch it
     */
    void setMaintenance(boolean on) {
        if (token == null) {
            throw new IllegalStateException("rbacr isn't configured (RBACR_TOKEN)");
        }
        Reply reply;
        try {
            reply = transport.send("PATCH", base.resolve("/api/systems/" + system), token,
                    "{\"maintenance\":" + on + "}");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("interrupted switching maintenance in rbacr", e);
        } catch (Exception e) {
            throw new IllegalStateException("rbacr didn't answer a maintenance switch", e);
        } finally {
            mode = null;
        }
        if (reply.status() / 100 != 2) {
            throw new IllegalStateException("rbacr refused to switch maintenance: HTTP " + reply.status());
        }
        mode = new Mode(on, clock.instant());
    }

    /**
     * The flag in an answer of {@code GET /api/systems/:id}, {@code {"id":
     * "<system>", ..., "maintenance": true}}: false when it has none (an
     * rbacr from before maintenance mode); null when it isn't {@code
     * system}'s.
     */
    static Boolean maintenance(String body, String system) {
        if (body == null || !Pattern.compile("\"id\"\\s*:\\s*\"" + Pattern.quote(system) + "\"").matcher(body).find()) {
            return null;
        }
        var flag = MAINTENANCE.matcher(body);
        return flag.find() && flag.group(1).equals("true");
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
