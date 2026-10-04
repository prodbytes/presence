package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

import static presence.auth.AuthHandler.response;

/**
 * Profiles (see {@link Profiles}): one person's cloud folder, whichever of
 * their Google accounts signs in. The HTTP API's JWT authorizer has already
 * verified the Google ID token; every route needs a verified email.
 * <ul>
 *   <li>{@code POST /api/auth/credentials} ({@code presence_user} only): an
 *       OpenID token for the profile's Cognito identity, as {@code
 *       {"identityId", "token"}}, which the app trades for AWS credentials
 *       ({@code GetCredentialsForIdentity}). An account's first call makes
 *       its profile, on the identity its Google sign-in already had, so data
 *       uploaded before profiles stays where it is;</li>
 *   <li>{@code GET /api/auth/profile}: the profile's accounts, as {@code
 *       {"accounts": [{email, owner, current}]}}, the owner first;</li>
 *   <li>{@code POST /api/auth/profile/link-code} ({@code presence_user}
 *       only): a one-time code, valid for {@link #CODE_TTL}, as {@code
 *       {"code": "ABCD-EFGH", "expiresAt"}};</li>
 *   <li>{@code POST /api/auth/profile/link}: the signed-in account joins the
 *       profile of the code in the (plain-text) body, and gets its roles.
 *       Refused (409) if the account has cloud data of its own, or owns a
 *       profile other accounts are linked to;</li>
 *   <li>{@code POST /api/auth/profile/unlink}: removes the account with the
 *       email in the body from the caller's profile (not the owner). Its
 *       next sign-in makes it a profile of its own again.</li>
 * </ul>
 */
public class ProfileHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** How long a link code works. */
    static final Duration CODE_TTL = Duration.ofMinutes(10);

    /** Link code characters: no I, O, 0 or 1, which read alike. 32 of them, so 40 bits in 8. */
    static final String CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    static final int CODE_LENGTH = 8;

    private final Roles roles;
    private final Profiles.Backend backend;
    private final boolean configured;
    private final Clock clock;
    private final SecureRandom random;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public ProfileHandler() {
        this(AuthHandler.fromEnvironment(), ProfileBackend.fromEnvironment(),
                ProfileBackend.configured(), Clock.systemUTC(), new SecureRandom());
    }

    /**
     * @param configured whether cloud sync is set up (an identity pool and a
     *                   bucket); without it, only the listing answers
     */
    ProfileHandler(Roles roles, Profiles.Backend backend, boolean configured, Clock clock, SecureRandom random) {
        this.roles = roles;
        this.backend = backend;
        this.configured = configured;
        this.clock = clock;
        this.random = random;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var claims = AuthHandler.claims(event);
        var sub = claims.get("sub");
        var email = claims.get("email");
        var verified = "true".equalsIgnoreCase(claims.getOrDefault("email_verified", ""));
        if (sub == null || sub.isBlank() || email == null || email.isBlank() || !verified) {
            return response(403, "{\"error\":\"a verified email is required\"}");
        }
        var caller = new Caller(sub, email.strip().toLowerCase(Locale.ROOT), bearer(event));
        var route = event.getRouteKey() == null ? "" : event.getRouteKey();
        try {
            return switch (route) {
                case "GET /api/auth/profile" -> listing(caller);
                case "POST /api/auth/credentials" -> credentials(caller);
                case "POST /api/auth/profile/link-code" -> linkCode(caller);
                case "POST /api/auth/profile/link" -> link(caller, MembershipHandler.bodyText(event, 32));
                case "POST /api/auth/profile/unlink" -> unlink(caller, MembershipHandler.bodyText(event, 254));
                default -> response(404, "{\"error\":\"no such route\"}");
            };
        } catch (RuntimeException e) {
            // Cognito or DynamoDB failed: say so without their details.
            System.err.println("presence: " + route + " failed: " + e);
            return response(502, "{\"error\":\"the profile service failed; try again\"}");
        }
    }

    /** The signed-in account: its Google ID, verified email (lowercase) and ID token. */
    record Caller(String sub, String email, String idToken) {
    }

    private APIGatewayV2HTTPResponse credentials(Caller caller) {
        if (!configured) {
            return notConfigured();
        }
        if (!isUser(caller)) {
            return response(403, "{\"error\":\"presence_user is required\"}");
        }
        var account = ensureAccount(caller);
        var token = backend.openIdToken(account.identityId(), account.profileId());
        return response(200, "{\"identityId\":" + Json.string(account.identityId())
                + ",\"token\":" + Json.string(token) + "}");
    }

    private APIGatewayV2HTTPResponse linkCode(Caller caller) {
        if (!configured) {
            return notConfigured();
        }
        if (!isUser(caller)) {
            return response(403, "{\"error\":\"presence_user is required\"}");
        }
        var account = ensureAccount(caller);
        var code = newCode(random);
        var expiresAt = clock.instant().plus(CODE_TTL);
        backend.saveCode(hash(code), new Profiles.LinkCode(
                account.profileId(), account.identityId(), account.ownerEmail(), caller.email(), expiresAt));
        return response(201, "{\"code\":" + Json.string(code.substring(0, 4) + "-" + code.substring(4))
                + ",\"expiresAt\":" + Json.string(expiresAt.toString()) + "}");
    }

    private APIGatewayV2HTTPResponse link(Caller caller, String body) {
        if (!configured) {
            return notConfigured();
        }
        var code = normalizeCode(body);
        if (code == null) {
            return response(400, "{\"error\":\"the body must be a link code\"}");
        }
        var target = backend.takeCode(hash(code), clock.instant()).orElse(null);
        if (target == null) {
            return response(404, "{\"error\":\"the code is wrong, used or expired\"}");
        }
        var current = backend.account(caller.sub()).orElse(null);
        if (current != null && current.profileId().equals(target.profileId())) {
            return listing(caller);
        }
        if (current != null && current.owner()
                && backend.members(current.profileId()).stream().anyMatch(m -> !m.sub().equals(caller.sub()))) {
            return response(409, "{\"error\":\"other accounts are linked to this account; unlink them first\"}");
        }
        // An account that's a profile of its own (or none yet) keeps its data
        // where it is: link it only when there's none, so nothing is stranded.
        if (current == null || current.owner()) {
            var own = current != null ? current.identityId() : backend.googleIdentity(caller.idToken());
            if (!own.equals(target.identityId()) && !backend.folderEmpty(own)) {
                return response(409, "{\"error\":\"this account already has cloud data of its own\"}");
            }
        }
        backend.put(new Profiles.Account(caller.sub(), caller.email(), target.profileId(), target.identityId(),
                target.ownerEmail(), false, clock.instant()));
        return listing(caller);
    }

    private APIGatewayV2HTTPResponse unlink(Caller caller, String body) {
        var email = body == null ? "" : body.toLowerCase(Locale.ROOT);
        if (!AdminHandler.validEmail(email)) {
            return response(400, "{\"error\":\"the body must be an email\"}");
        }
        var account = backend.account(caller.sub()).orElse(null);
        var member = account == null ? null : backend.members(account.profileId()).stream()
                .filter(m -> m.email().equalsIgnoreCase(email))
                .findFirst().orElse(null);
        if (member == null) {
            return response(404, "{\"error\":\"no such account in this profile\"}");
        }
        if (member.owner()) {
            return response(409, "{\"error\":\"the profile's owner can't be unlinked\"}");
        }
        backend.delete(member.sub());
        return listing(caller);
    }

    /** The caller's profile's accounts, the owner first; just the caller before it has a profile. */
    private APIGatewayV2HTTPResponse listing(Caller caller) {
        var account = backend.account(caller.sub()).orElse(null);
        List<Profiles.Account> members = account == null
                ? List.of(new Profiles.Account(caller.sub(), caller.email(), "", "", caller.email(), true, null))
                : backend.members(account.profileId());
        return response(200, "{\"accounts\":[" + members.stream()
                .sorted(Comparator.comparing((Profiles.Account m) -> !m.owner()).thenComparing(Profiles.Account::email))
                .map(m -> "{\"email\":" + Json.string(m.email())
                        + ",\"owner\":" + m.owner()
                        + ",\"current\":" + m.sub().equals(caller.sub()) + "}")
                .collect(Collectors.joining(",")) + "]}");
    }

    /** The caller's account, made (with a profile of its own) on its first use. */
    private Profiles.Account ensureAccount(Caller caller) {
        var existing = backend.account(caller.sub());
        if (existing.isPresent()) {
            var account = existing.get();
            if (!account.email().equals(caller.email())) {
                account = new Profiles.Account(account.sub(), caller.email(), account.profileId(),
                        account.identityId(), account.owner() ? caller.email() : account.ownerEmail(),
                        account.owner(), account.linkedAt());
                backend.put(account);
            }
            return account;
        }
        // The identity Google sign-in already had, so earlier uploads stay put.
        var created = new Profiles.Account(caller.sub(), caller.email(), UUID.randomUUID().toString(),
                backend.googleIdentity(caller.idToken()), caller.email(), true, clock.instant());
        if (backend.create(created)) {
            return created;
        }
        // Another request made it first.
        return backend.account(caller.sub()).orElseThrow();
    }

    private boolean isUser(Caller caller) {
        var owner = backend.account(caller.sub()).map(Profiles.Account::ownerEmail).orElse(null);
        return roles.of(caller.email(), true, owner).contains(Roles.USER);
    }

    private static APIGatewayV2HTTPResponse notConfigured() {
        return response(503, "{\"error\":\"cloud sync isn't set up\"}");
    }

    /** The token from {@code Authorization: Bearer <token>} (verified by the authorizer). */
    static String bearer(APIGatewayV2HTTPEvent event) {
        Map<String, String> headers = event.getHeaders() == null ? Map.of() : event.getHeaders();
        var value = headers.getOrDefault("authorization", headers.getOrDefault("Authorization", ""));
        return value.regionMatches(true, 0, "Bearer ", 0, 7) ? value.substring(7).strip() : value.strip();
    }

    /** {@link #CODE_LENGTH} random characters from {@link #CODE_ALPHABET}. */
    static String newCode(SecureRandom random) {
        var code = new StringBuilder(CODE_LENGTH);
        for (var i = 0; i < CODE_LENGTH; i++) {
            code.append(CODE_ALPHABET.charAt(random.nextInt(CODE_ALPHABET.length())));
        }
        return code.toString();
    }

    /** A typed code, upper case, without spaces or dashes; null unless it's a well-formed code. */
    static String normalizeCode(String typed) {
        if (typed == null) {
            return null;
        }
        var code = typed.toUpperCase(Locale.ROOT).replaceAll("[\\s-]", "");
        return code.length() == CODE_LENGTH && code.chars().allMatch(c -> CODE_ALPHABET.indexOf(c) >= 0) ? code : null;
    }

    /** Codes are stored by their SHA-256, so the table never holds a usable code. */
    static String hash(String code) {
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256").digest(code.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }
}
