package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

import static presence.auth.Http.response;

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
 *       the live-sync IoT policy ({@link Backend#allowLiveSync}). The body,
 *       the device's ID (plain text, or empty), adds the device to the end of
 *       the profile's devices (up to {@link #PREMIUM_DEVICES}); the answer
 *       also has {@code "deviceLimit"} (the first {@link #FREE_DEVICES}
 *       show for a free profile, {@link #PREMIUM_DEVICES} for a premium
 *       one) and {@code "devices"}, in the order they were added;</li>
 *   <li>{@code POST /api/auth/profile/devices/remove} ({@code presence_user}
 *       only): takes the device in the body out of the profile's devices,
 *       answering {@code {"deviceLimit", "devices"}};</li>
 *   <li>{@code GET /api/auth/profile}: the caller's profile, made (and
 *       linked to the caller) at its first sign-in, as {@code {"profile",
 *       "shared": [...], "accounts": [{email, owner, current}]}}: {@code
 *       shared} is what the caller gets from the profile's owner ({@link
 *       Roles#shared}: {@code presence_user} and {@code presence_premium}
 *       when the owner has them; empty for the owner), {@code accounts} the
 *       profile's subjects, the owner first. The app asks it at every
 *       sign-in, and its own roles from rbacr;</li>
 *   <li>{@code POST /api/auth/profile/link-code} ({@code presence_user}
 *       only): a one-time code, valid for {@link #CODE_TTL}, as {@code
 *       {"code": "ABCD-EFGH", "expiresAt"}};</li>
 *   <li>{@code POST /api/auth/profile/link}: the signed-in subject joins the
 *       profile of the code in the (plain-text) body, and shares its
 *       owner's membership ({@code presence_user}; never the owner's
 *       {@code presence_admin} or {@code presence_root}, see
 *       {@link Roles#shared}), and answers the listing. Refused (409) if the
 *       subject owns a profile with cloud data, or one other subjects are
 *       linked to; a refusal leaves the code usable, which is used up
 *       only by a link that's made;</li>
 *   <li>{@code POST /api/auth/profile/unlink}: removes the subject with the
 *       email in the body from the caller's profile (not the owner). Its
 *       next sign-in makes it a profile of its own again. Answers the
 *       listing.</li>
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

        /** The code under {@code hash}, if it's there and hasn't expired by {@code now}; it stays. */
        Optional<LinkCode> peekCode(String hash, Instant now);

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

        /**
         * {@link #openIdToken(String, String, String)}, tagged with the
         * profile's {@link #TIER_TAG} ({@link #PREMIUM} or {@link #FREE}):
         * Cognito puts it on the credentials' session, and the role's S3
         * permissions require {@link #PREMIUM} (presence_infra/identity.yaml).
         */
        default String openIdToken(String identityId, String profileId, String googleIdToken, String tier) {
            return openIdToken(identityId, profileId, googleIdToken);
        }

        /**
         * {@link #openIdToken(String, String, String, String)}, also tagged
         * {@link #ADMIN_TAG} {@code true} for an administrator (from the
         * caller's own email, never a linked owner's): the role's Feedback
         * permissions let it read every conversation and reply
         * (presence_infra/identity.yaml).
         */
        default String openIdToken(String identityId, String profileId, String googleIdToken, String tier,
                                   boolean admin) {
            return openIdToken(identityId, profileId, googleIdToken, tier);
        }

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

    /** The principal tag the credentials carry: whether they may use the bucket. */
    static final String TIER_TAG = "tier";

    /** The principal tag of administrators' credentials ({@code true}), for Feedback. */
    static final String ADMIN_TAG = "admin";

    /** {@link #TIER_TAG}'s value for {@link Roles#PREMIUM}: S3 and live sync. */
    static final String PREMIUM = "premium";

    /** {@link #TIER_TAG}'s value otherwise: live sync only. */
    static final String FREE = "free";

    /** How many of a free profile's devices show their events: its first two. */
    static final int FREE_DEVICES = 2;

    /** How many of a premium profile's devices show theirs, and the most a profile lists. */
    static final int PREMIUM_DEVICES = 50;

    /** The longest device ID taken. */
    static final int MAX_DEVICE_ID = 64;

    private static final Pattern DEVICE_ID = Pattern.compile("[a-z]+_[a-z]+_[a-z]+");

    private final Roles roles;
    private final Profiles profiles;
    private final Backend backend;
    private final boolean configured;
    private final SecureRandom random;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public ProfileHandler() {
        this(Roles.fromEnvironment(), Profiles.fromEnvironment(), ProfileBackend.fromEnvironment(),
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
        var caller = Caller.from(event);
        if (!caller.hasSubject() || caller.verifiedEmail() == null) {
            return response(403, "{\"error\":\"a verified email is required\"}");
        }
        var route = Http.route(event);
        try {
            return switch (route) {
                case "GET /api/auth/profile" -> listing(caller);
                case "POST /api/auth/credentials" -> credentials(caller, Http.bodyText(event, MAX_DEVICE_ID));
                case "POST /api/auth/profile/devices/remove" ->
                        removeDevice(caller, Http.bodyText(event, MAX_DEVICE_ID));
                case "POST /api/auth/profile/link-code" -> linkCode(caller);
                case "POST /api/auth/profile/link" -> link(caller, Http.bodyText(event, 32));
                case "POST /api/auth/profile/unlink" -> unlink(caller, Http.bodyText(event, 254));
                default -> response(404, "{\"error\":\"no such route\"}");
            };
        } catch (RuntimeException e) {
            // Cognito or DynamoDB failed: say which and how, not AWS's message.
            return Aws.failed("profile", route, e, context);
        }
    }

    private Profiles.Profile profile(Caller caller) {
        return profiles.profile(caller, null);
    }

    private APIGatewayV2HTTPResponse credentials(Caller caller, String device) {
        if (!configured) {
            return notConfigured();
        }
        if (device == null || (!device.isEmpty() && !validDevice(device))) {
            return response(400, "{\"error\":\"the body must be a device ID, or empty\"}");
        }
        var profile = profile(caller);
        var granted = roles.of(caller, profile);
        if (!granted.contains(Roles.USER)) {
            return response(403, "{\"error\":\"presence_user is required\"}");
        }
        profile = withIdentity(caller, profile);
        var premium = granted.contains(Roles.PREMIUM);
        var tier = premium ? PREMIUM : FREE;
        // Administration is never shared with a linked owner (Roles.of).
        var admin = granted.contains(Roles.ADMIN);
        var token = backend.openIdToken(profile.identityId(), profile.id(), caller.idToken(), tier, admin);
        backend.allowLiveSync(profile.identityId());
        // Every device is listed, up to Premium's limit, whatever the tier:
        // a profile that becomes premium shows the devices it already had.
        var devices = device.isEmpty()
                ? profiles.store().devices(profile.id())
                : profiles.store().addDevice(profile.id(), device, PREMIUM_DEVICES);
        return response(200, "{\"identityId\":" + Json.string(profile.identityId())
                + ",\"token\":" + Json.string(token)
                + ",\"deviceLimit\":" + (premium ? PREMIUM_DEVICES : FREE_DEVICES)
                + ",\"devices\":" + devicesJson(devices)
                + ",\"tier\":" + Json.string(tier) + "}");
    }

    /**
     * Takes the device in the body out of the profile's devices (the app
     * deleted it), so a later one takes its place among the devices that
     * show; it's added again, at the end, if it asks for credentials again.
     */
    private APIGatewayV2HTTPResponse removeDevice(Caller caller, String device) {
        if (!configured) {
            return notConfigured();
        }
        if (!validDevice(device)) {
            return response(400, "{\"error\":\"the body must be a device ID\"}");
        }
        var profile = profile(caller);
        var granted = roles.of(caller, profile);
        if (!granted.contains(Roles.USER)) {
            return response(403, "{\"error\":\"presence_user is required\"}");
        }
        var devices = profiles.store().removeDevice(profile.id(), device);
        return response(200, "{\"deviceLimit\":" + (granted.contains(Roles.PREMIUM) ? PREMIUM_DEVICES : FREE_DEVICES)
                + ",\"devices\":" + devicesJson(devices) + "}");
    }

    /** A device ID as the app makes them: {@code adjective_adjective_thing}. */
    static boolean validDevice(String device) {
        return device != null && device.length() <= MAX_DEVICE_ID && DEVICE_ID.matcher(device).matches();
    }

    private static String devicesJson(List<String> devices) {
        return devices.stream().map(Json::string).collect(Collectors.joining(",", "[", "]"));
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
        backend.saveCode(hash(code), new LinkCode(profile.id(), caller.verifiedEmail(), expiresAt));
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
        var hash = hash(code);
        var now = profiles.clock().instant();
        // Refusals come first and leave the code; only a link uses it up.
        var pending = backend.peekCode(hash, now).orElse(null);
        var target = pending == null ? null : profiles.store().profile(pending.profileId());
        if (target == null) {
            return response(404, "{\"error\":\"the code is wrong, used or expired\"}");
        }
        var current = profile(caller);
        if (current.id().equals(target.id())) {
            backend.takeCode(hash, now);
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
        // One use: whoever deletes it first links (a conditional delete).
        if (backend.takeCode(hash, now).isEmpty()) {
            return response(404, "{\"error\":\"the code is wrong, used or expired\"}");
        }
        profiles.store().relink(caller.subject(), target.id(), caller.verifiedEmail(), now);
        return listing(caller);
    }

    private APIGatewayV2HTTPResponse unlink(Caller caller, String body) {
        var email = body == null ? "" : body.toLowerCase(Locale.ROOT);
        if (!validEmail(email)) {
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

    /** An email as an account's: one {@code @}, not at either end, no spaces or commas. */
    static boolean validEmail(String email) {
        var at = email.lastIndexOf('@');
        return email.length() <= 254 && at > 0 && at < email.length() - 1
                && email.chars().noneMatch(c -> c <= ' ' || c == ',');
    }

    /**
     * The caller's profile, the roles it {@link Roles#shared shares} from
     * the profile's owner (sorted) and its subjects, the owner first.
     */
    private APIGatewayV2HTTPResponse listing(Caller caller) {
        var profile = profile(caller);
        return response(200, "{\"profile\":" + Json.string(profile.id())
                + ",\"shared\":" + roles.shared(caller, profile).stream().map(Json::string)
                .collect(Collectors.joining(",", "[", "]"))
                + ",\"accounts\":["
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
        return roles.of(caller, profile).contains(Roles.USER);
    }

    private static APIGatewayV2HTTPResponse notConfigured() {
        return response(503, "{\"error\":\"cloud sync isn't set up\"}");
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
