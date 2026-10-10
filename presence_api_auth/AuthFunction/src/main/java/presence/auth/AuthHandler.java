package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.util.stream.Collectors;

import static presence.auth.Http.response;

/**
 * {@code GET /api/auth}: the signed-in user's {@link Profiles profile} and
 * roles, as {@code {"email": "...", "profile": "<id>", "roles": [...]}}. The
 * profile is found by the token's subject ({@code iss} and {@code sub}), or
 * created and linked to it at the first sign-in, with the app's own profile
 * ID ({@code ?profile=<id>}) when that's free: the first sign-in claims the
 * profile the app made at its start. The HTTP API's JWT
 * authorizer has already verified the Google ID token, so the claims can be
 * trusted ({@link Caller}).
 *
 * <p>{@code GET /api/auth/anonymous} (no token, no authorizer): the
 * {@link ExecutionMode}, the anonymous user's roles and which expected
 * {@link Settings} are set, as {@code {"mode": "RBAC", "roles":
 * ["presence_anonymous"], "settings": {"oidc": true, "aws": true},
 * "maintenance": {"on": false, "message": ""}}}. The app asks it before it
 * shows anything, and again every minute: in {@link Maintenance} it shows
 * only a sorry message, except to admins.
 */
public class AuthHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    static final String ANONYMOUS_ROUTE = "GET /api/auth/anonymous";

    private final Roles roles;
    private final Profiles profiles;
    private final ExecutionMode mode;
    private final Settings settings;
    private final Maintenance.Store maintenance;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AuthHandler() {
        this(Roles.fromEnvironment(), Profiles.fromEnvironment(), ExecutionMode.fromEnvironment(),
                Settings.fromEnvironment(), Maintenance.dynamoStore(System.getenv("SYSTEM_TABLE")));
    }

    AuthHandler(Roles roles, Profiles profiles) {
        this(roles, profiles, ExecutionMode.RBAC);
    }

    AuthHandler(Roles roles, Profiles profiles, ExecutionMode mode) {
        this(roles, profiles, mode, new Settings(mode == ExecutionMode.RBAC, false));
    }

    AuthHandler(Roles roles, Profiles profiles, ExecutionMode mode, Settings settings) {
        this(roles, profiles, mode, settings, Maintenance.memory());
    }

    AuthHandler(Roles roles, Profiles profiles, ExecutionMode mode, Settings settings,
                Maintenance.Store maintenance) {
        this.roles = roles;
        this.profiles = profiles;
        this.mode = mode;
        this.settings = settings;
        this.maintenance = maintenance;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var route = Http.route(event);
        if (ANONYMOUS_ROUTE.equals(route)) {
            return response(200, "{\"mode\":" + Json.string(mode.name()) + ",\"roles\":["
                    + Roles.anonymous(mode).stream().map(Json::string).collect(Collectors.joining(","))
                    + "],\"settings\":" + settings.toJson()
                    + ",\"maintenance\":" + maintenance().toPublicJson() + "}");
        }
        try {
            var caller = Caller.from(event);
            var profile = profiles.profile(caller, Http.query(event, "profile"));
            // A linked subject shares its profile owner's membership.
            var granted = roles.of(caller, profile);
            var body = "{\"email\":" + (caller.email() == null ? "null" : Json.string(caller.email()))
                    + ",\"profile\":" + (profile == null ? "null" : Json.string(profile.id()))
                    + ",\"roles\":[" + granted.stream().map(Json::string).collect(Collectors.joining(","))
                    + "]}";
            return response(200, body);
        } catch (RuntimeException e) {
            return Aws.failed("auth", route, e, context);
        }
    }

    /**
     * The maintenance state; off if it can't be read, so a DynamoDB outage
     * doesn't shut everyone out (the start check must always answer).
     */
    private Maintenance maintenance() {
        try {
            return maintenance.get();
        } catch (RuntimeException e) {
            System.err.println("presence: could not read maintenance mode (answering off): " + Aws.cause(e) + ": " + e);
            return Maintenance.OFF;
        }
    }
}
