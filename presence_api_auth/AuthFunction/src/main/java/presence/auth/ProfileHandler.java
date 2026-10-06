package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.awscore.exception.AwsServiceException;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.stream.Collectors;

import static presence.auth.AuthHandler.response;

/**
 * A {@link Profiles profile}'s cloud folder and linked subjects, whichever
 * of its Google accounts signs in. The HTTP API's JWT authorizer has
 * already verified the Google ID token; every route needs a verified email.
 * <ul>
 *   <li>{@code POST /api/auth/credentials} ({@code presence_user} only): an
 *       OpenID token for the profile's Cognito identity, as {@code
 *       {"identityId", "token"}}, which the app trades for AWS credentials
 *       ({@code GetCredentialsForIdentity}). A profile's first call gives it
 *       the identity the caller's Google sign-in already had, so data
 *       uploaded before profiles stays where it is. The identity also gets
 *       the live-sync IoT policy ({@link Backend#allowLiveSync});</li>
 *   <li>{@code GET /api/auth/profile}: the profile's subjects, as {@code
 *       {"profile", "accounts": [{email, owner, current}]}}, the owner first;</li>
 *   <li>{@code POST /api/auth/profile/link-code} ({@code presence_user}
 *       only): a one-time code, valid for {@link #CODE_TTL}, as {@code
 *       {"code": "ABCD-EFGH", "expiresAt"}};</li>
 *   <li>{@code POST /api/auth/profile/link}: the signed-in subject joins the
 *       profile of the code in the (plain-text) body, and gets its roles.
 *       Refused (409) if the subject owns a profile with cloud data, or
 *       one other subjects are linked to;</li>
 *   <li>{@code POST /api/auth/profile/unlink}: removes the subject with the
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

    /** A link code, as stored (by its hash): which profile it joins, who made it, and until when. */
    record LinkCode(String profileId, String createdBy, Instant expiresAt) {
    }

    /** Link codes, Cognito and S3: {@link ProfileBackend} in AWS; fakes in tests. */
    interface Backend {
        /** Keeps {@code code} under {@code hash} until it expires. */
        void saveCode(String hash, LinkCode code);

        /** Removes and returns the code under {@code hash}, if it's there and hasn't expired by {@code now}. */
        Optional<LinkCode> takeCode(String hash, Instant now);

        /**
         * The Cognito identity the Google ID token signs in to directly
         * ({@code GetId}): where its data went before profiles, or a new,
         * empty identity.
         */
        String googleIdentity(String googleIdToken);

        /**
         * An OpenID token for the profile's identity
         * ({@code GetOpenIdTokenForDeveloperIdentity}). The first call links
         * the profile to the identity, which Cognito allows only with one of
         * the identity's logins: the caller's Google ID token, when it signs
         * in to that identity.
         */
        String openIdToken(String identityId, String profileId, String googleIdToken);

        /** Whether the identity's folder in the bucket holds nothing. */
        boolean folderEmpty(String identityId);

        /**
         * Lets the identity use live sync: attaches the IoT policy to it
         * ({@code iot:AttachPolicy}, idempotent), which AWS IoT requires of
         * authenticated Cognito identities besides their role's permissions.
         * Never fails: without it, the app still syncs through the bucket.
         */
        void allowLiveSync(String identityId);
    }

    private final Roles roles;
    private final Profiles profiles;
    private final Backend backend;
    private final boolean configured;
    private final SecureRandom random;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public ProfileHandler() {
        this(AuthHandler.fromEnvironment(), AuthHandler.profilesFromEnvironment(), ProfileBackend.fromEnvironment(),
                ProfileBackend.configured(), new SecureRandom());
    }

    /**
     * @param configured whether cloud sync is set up (an identity pool and a
     *                   bucket); without it, only the listing answers
     */
    ProfileHandler(Roles roles, Profiles profiles, Backend backend, boolean configured, SecureRandom random) {
        this.roles = roles;
        this.profiles = profiles;
        this.backend = backend;
        this.configured = configured;
        this.random = random;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var claims = AuthHandler.claims(event);
        var iss = claims.get("iss");
        var sub = claims.get("sub");
        var email = claims.get("email");
        var verified = "true".equalsIgnoreCase(claims.getOrDefault("email_verified", ""));
        if (iss == null || iss.isBlank() || sub == null || sub.isBlank()
                || email == null || email.isBlank() || !verified) {
            return response(403, "{\"error\":\"a verified email is required\"}");
        }
        var caller = new Caller(iss, sub, email.strip().toLowerCase(Locale.ROOT), bearer(event));
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
            // Cognito or DynamoDB failed: say which and how (its error code),
            // and the request ID that finds the full error in the log, but
            // not AWS's message, which names ARNs.
            var requestId = context == null ? null : context.getAwsRequestId();
            System.err.println("presence: " + route + " failed (request " + requestId + "): "
                    + cause(e) + ": " + e);
            return response(502, "{\"error\":\"the profile service failed\",\"cause\":"
                    + Json.string(cause(e))
                    + (requestId == null ? "" : ",\"requestId\":" + Json.string(requestId)) + "}");
        }
    }

    /**
     * What failed, for the caller: an AWS service, the operation (when the
     * SDK client called it) and its error code, or the exception's type.
     */
    static String cause(RuntimeException e) {
        if (e instanceof AwsServiceException aws && aws.awsErrorDetails() != null) {
            var details = aws.awsErrorDetails();
            var cause = details.serviceName() + operation(e).map(op -> " " + op + ":").orElse("")
                    + " " + details.errorCode() + " (HTTP " + aws.statusCode() + ")";
            // AWS knows every operation the SDK sends; an endpoint that
            // doesn't is an emulator, such as Floci locally.
            if ("UnknownOperationException".equals(details.errorCode())) {
                cause += "; the endpoint doesn't implement it (a local AWS emulator?)";
            }
            return cause;
        }
        return e.getClass().getSimpleName();
    }

    /**
     * The AWS operation that threw {@code e}: the SDK client's method in its
     * stack trace ({@code DefaultCognitoIdentityClient.getId} is
     * {@code GetId}), if it's there.
     */
    static Optional<String> operation(Throwable e) {
        for (var frame : e.getStackTrace()) {
            var type = frame.getClassName();
            if (type.startsWith("software.amazon.awssdk.services.")
                    && type.substring(type.lastIndexOf('.') + 1).startsWith("Default")
                    && type.endsWith("Client")) {
                var method = frame.getMethodName();
                return Optional.of(Character.toUpperCase(method.charAt(0)) + method.substring(1));
            }
        }
        return Optional.empty();
    }

    /** The signed-in subject: its issuer and Google ID, verified email (lowercase) and ID token. */
    record Caller(String iss, String sub, String email, String idToken) {

        String subject() {
            return Profiles.subject(iss, sub);
        }
    }

    private Profiles.Profile profile(Caller caller) {
        return profiles.profile(caller.iss(), caller.sub(), caller.email());
    }

    private APIGatewayV2HTTPResponse credentials(Caller caller) {
        if (!configured) {
            return notConfigured();
        }
        var profile = profile(caller);
        if (!isUser(caller, profile)) {
            return response(403, "{\"error\":\"presence_user is required\"}");
        }
        profile = withIdentity(caller, profile);
        var token = backend.openIdToken(profile.identityId(), profile.id(), caller.idToken());
        backend.allowLiveSync(profile.identityId());
        return response(200, "{\"identityId\":" + Json.string(profile.identityId())
                + ",\"token\":" + Json.string(token) + "}");
    }

    private APIGatewayV2HTTPResponse linkCode(Caller caller) {
        if (!configured) {
            return notConfigured();
        }
        var profile = profile(caller);
        if (!isUser(caller, profile)) {
            return response(403, "{\"error\":\"presence_user is required\"}");
        }
        // The folder is settled, and the profile linked to it, before anyone
        // joins it: a member's Google token can't link it.
        profile = withIdentity(caller, profile);
        backend.openIdToken(profile.identityId(), profile.id(), caller.idToken());
        var code = newCode(random);
        var expiresAt = profiles.clock().instant().plus(CODE_TTL);
        backend.saveCode(hash(code), new LinkCode(profile.id(), caller.email(), expiresAt));
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
        var taken = backend.takeCode(hash(code), profiles.clock().instant()).orElse(null);
        var target = taken == null ? null : profiles.store().profile(taken.profileId());
        if (target == null) {
            return response(404, "{\"error\":\"the code is wrong, used or expired\"}");
        }
        var current = profile(caller);
        if (current.id().equals(target.id())) {
            return listing(caller);
        }
        if (caller.subject().equals(current.ownerSubject())) {
            if (profiles.store().members(current.id()).stream()
                    .anyMatch(m -> !m.subject().equals(caller.subject()))) {
                return response(409, "{\"error\":\"other accounts are linked to this account; unlink them first\"}");
            }
            // A profile of its own keeps its data where it is: link it only
            // when there's none, so nothing is stranded.
            var own = current.hasIdentity() ? current.identityId() : backend.googleIdentity(caller.idToken());
            if (!own.equals(target.identityId()) && !backend.folderEmpty(own)) {
                return response(409, "{\"error\":\"this account already has cloud data of its own\"}");
            }
        }
        profiles.store().relink(caller.subject(), target.id(), caller.email(), profiles.clock().instant());
        return listing(caller);
    }

    private APIGatewayV2HTTPResponse unlink(Caller caller, String body) {
        var email = body == null ? "" : body.toLowerCase(Locale.ROOT);
        if (!AdminHandler.validEmail(email)) {
            return response(400, "{\"error\":\"the body must be an email\"}");
        }
        var profile = profile(caller);
        var member = profiles.store().members(profile.id()).stream()
                .filter(m -> m.email().equalsIgnoreCase(email))
                .findFirst().orElse(null);
        if (member == null) {
            return response(404, "{\"error\":\"no such account in this profile\"}");
        }
        if (member.subject().equals(profile.ownerSubject())) {
            return response(409, "{\"error\":\"the profile's owner can't be unlinked\"}");
        }
        profiles.store().unlink(member.subject());
        return listing(caller);
    }

    /** The caller's profile and its subjects, the owner first. */
    private APIGatewayV2HTTPResponse listing(Caller caller) {
        var profile = profile(caller);
        return response(200, "{\"profile\":" + Json.string(profile.id()) + ",\"accounts\":["
                + profiles.store().members(profile.id()).stream()
                .sorted(Comparator.comparing((Profiles.Member m) -> !m.subject().equals(profile.ownerSubject()))
                        .thenComparing(Profiles.Member::email))
                .map(m -> "{\"email\":" + Json.string(m.email())
                        + ",\"owner\":" + m.subject().equals(profile.ownerSubject())
                        + ",\"current\":" + m.subject().equals(caller.subject()) + "}")
                .collect(Collectors.joining(",")) + "]}");
    }

    /** The profile, with its identity: the caller's Google one if it had none yet. */
    private Profiles.Profile withIdentity(Caller caller, Profiles.Profile profile) {
        if (profile.hasIdentity()) {
            return profile;
        }
        return profiles.store().identity(profile.id(), backend.googleIdentity(caller.idToken()));
    }

    private boolean isUser(Caller caller, Profiles.Profile profile) {
        return roles.of(caller.email(), true, profile.ownerEmail()).contains(Roles.USER);
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
