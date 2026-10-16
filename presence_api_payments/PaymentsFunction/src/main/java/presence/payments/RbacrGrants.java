package presence.payments;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.time.temporal.ChronoUnit;
import java.util.Map;

/**
 * Gives and takes back rbacr's {@code premium} role (in the app's system)
 * for store subscriptions, with an rbacr root's API token: only roots may
 * grant (rbacr's P1), and asking about someone else's roles needs one too
 * (T6).
 *
 * <p>A grant runs until the subscription's paid period ends, plus a little
 * grace, and is moved by granting again (rbacr's G2: a grantee holds a role
 * through one grant; the same validity changes nothing, another replaces
 * it). G2 would also replace a longer grant someone else made (a voucher's,
 * which never ends, or a root's), so it first asks rbacr ({@code POST
 * /api/check}) how long the email holds {@code premium} already, and grants
 * only when that's less. Ending one, it revokes the address's grant only
 * when rbacr's end is still the one it granted.
 */
final class RbacrGrants {

    /** The role store subscribers get. */
    static final String ROLE = "premium";

    /**
     * The role a free member holds (a nu01.com Free subscription's): what
     * Join free in the mobile apps grants, and the only role it may.
     */
    static final String FREE = "free";

    private final URI base;
    private final String token;
    private final String system;
    private final Web web;

    /** @param token null when grants aren't configured */
    RbacrGrants(URI base, String token, String system, Web web) {
        this.base = base;
        this.token = token;
        this.system = system;
        this.web = web;
    }

    /** From {@code RBACR_URL}, {@code RBACR_GRANT_TOKEN} and {@code RBACR_SYSTEM}. */
    static RbacrGrants fromEnvironment(Web web) {
        var token = System.getenv("RBACR_GRANT_TOKEN");
        var url = System.getenv().getOrDefault("RBACR_URL", "");
        var system = System.getenv().getOrDefault("RBACR_SYSTEM", "");
        return new RbacrGrants(URI.create(url.isBlank() ? "https://rbacr.nu01.com" : url.strip()),
                token == null || token.isBlank() ? null : token.strip(),
                system.isBlank() ? Rbacr.SYSTEM : system.strip(), web);
    }

    /** Whether it has a token to grant with. */
    boolean configured() {
        return token != null;
    }

    /** rbacr failed, or refused the token. */
    static final class Failed extends Exception {
        Failed(String message) {
            super(message);
        }
    }

    /**
     * How long {@code email} holds {@code premium} now: {@link Instant#MAX}
     * for a grant that never ends (or a root), null when it doesn't.
     */
    Instant holdsUntil(String email) throws Failed {
        return holdsUntil(email, ROLE);
    }

    /**
     * How long {@code email} holds {@code role} now (rbacr's effective
     * roles: implied ones count, so {@code premium} gives {@code free}):
     * {@link Instant#MAX} for a grant that never ends (or a root), null when
     * it doesn't.
     */
    Instant holdsUntil(String email, String role) throws Failed {
        var reply = send("POST", "/api/check", "{\"email\":" + Json.string(email) + ",\"systemId\":"
                + Json.string(system) + ",\"role\":" + Json.string(role) + "}");
        if (reply.status() != 200) {
            throw new Failed("rbacr's check answered " + reply.status());
        }
        try {
            var answer = JsonReader.object(reply.body());
            if (!Boolean.TRUE.equals(answer.get("allowed"))) {
                return null;
            }
            var expires = JsonReader.string(answer, "expiresAt");
            return expires == null ? Instant.MAX : Instant.parse(expires);
        } catch (IllegalArgumentException | DateTimeParseException e) {
            throw new Failed("rbacr's check isn't an answer");
        }
    }

    /**
     * Makes {@code email} hold {@code premium} until at least {@code until}
     * (whole seconds); returns the end it granted, or null when an existing
     * grant already lasts as long.
     */
    Instant extend(String email, Instant until) throws Failed {
        var end = until.truncatedTo(ChronoUnit.SECONDS);
        var holds = holdsUntil(email);
        if (holds != null && !holds.isBefore(end)) {
            return null;
        }
        var reply = send("POST", "/api/systems/" + path(system) + "/grants", "{\"role\":\"" + ROLE
                + "\",\"grantee\":" + Json.string(email) + ",\"endsAt\":" + Json.string(end.toString()) + "}");
        if (reply.status() != 200 && reply.status() != 201) {
            throw new Failed("rbacr's grant answered " + reply.status());
        }
        return end;
    }

    /**
     * Gives {@code email} {@link #FREE} for good (no end), unless it holds
     * it already (by any grant, an implied role or as a root); whether it
     * granted. The role is fixed here: nothing else can be granted this way.
     */
    boolean joinFree(String email) throws Failed {
        if (holdsUntil(email, FREE) != null) {
            return false;
        }
        var reply = send("POST", "/api/systems/" + path(system) + "/grants", "{\"role\":\"" + FREE
                + "\",\"grantee\":" + Json.string(email) + "}");
        if (reply.status() != 200 && reply.status() != 201) {
            throw new Failed("rbacr's grant answered " + reply.status());
        }
        return true;
    }

    /**
     * Takes {@code premium} back from {@code email}, when its grant is still
     * the one that ends at {@code granted} (the end {@link #extend} gave);
     * whether it did.
     */
    boolean end(String email, Instant granted) throws Failed {
        if (granted == null) {
            return false;
        }
        var holds = holdsUntil(email);
        if (holds == null || holds.equals(Instant.MAX)
                || holds.getEpochSecond() != granted.getEpochSecond()) {
            return false;
        }
        var reply = send("DELETE", "/api/systems/" + path(system) + "/grants",
                "{\"role\":\"" + ROLE + "\",\"grantee\":" + Json.string(email) + "}");
        if (reply.status() != 204 && reply.status() != 200 && reply.status() != 404) {
            throw new Failed("rbacr's revoke answered " + reply.status());
        }
        return reply.status() != 404;
    }

    private Web.Reply send(String method, String path, String body) throws Failed {
        if (token == null) {
            throw new Failed("no rbacr grant token");
        }
        try {
            return web.send(method, base.resolve(path),
                    Map.of("authorization", "Bearer " + token, "content-type", "application/json"), body);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Failed("interrupted");
        } catch (Exception e) {
            throw new Failed("rbacr didn't answer: " + e.getClass().getSimpleName());
        }
    }

    private static String path(String segment) {
        return URLEncoder.encode(segment, StandardCharsets.UTF_8);
    }
}
