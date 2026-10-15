package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.util.Map;
import java.util.stream.Collectors;

import static presence.auth.Http.response;

/**
 * {@code GET /api/auth/anonymous} (no token, no authorizer): the
 * {@link ExecutionMode}, the anonymous user's roles and which expected
 * {@link Settings} are set, as {@code {"mode": "RBAC", "roles":
 * ["presence_anonymous"], "settings": {"oidc": true, "aws": true,
 * "rbacr": true}}}. The app asks it before it shows anything, and then
 * every 15 min. The answer is the same for every caller, so the site's
 * CDN keeps it for {@link #MAX_AGE} (presence_infra/site.yaml).
 *
 * <p>A signed-in user's own roles, maintenance mode and vouchers are
 * rbacr's: the app asks rbacr for them directly with the user's Google ID
 * token. The profile (made at the first sign-in) and the roles it shares
 * are {@link ProfileHandler}'s {@code GET /api/auth/profile}.
 */
public class AuthHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    static final String ANONYMOUS_ROUTE = "GET /api/auth/anonymous";

    /** How long the CDN (and a browser) may keep the anonymous answer: {@code Cache-Control: max-age}. */
    static final int MAX_AGE = 60;

    private final ExecutionMode mode;
    private final Settings settings;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AuthHandler() {
        this(ExecutionMode.fromEnvironment(), Settings.fromEnvironment());
    }

    AuthHandler(ExecutionMode mode) {
        this(mode, new Settings(mode == ExecutionMode.RBAC, false));
    }

    AuthHandler(ExecutionMode mode, Settings settings) {
        this.mode = mode;
        this.settings = settings;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        // Only through the site (CloudFront), never the API's own host.
        if (!OriginCheck.fromEnvironment().allows(event)) {
            return OriginCheck.refused();
        }
        if (!ANONYMOUS_ROUTE.equals(Http.route(event))) {
            return response(404, "{\"error\":\"no such route\"}");
        }
        var answer = response(200, "{\"mode\":" + Json.string(mode.name()) + ",\"roles\":["
                + Roles.anonymous(mode).stream().map(Json::string).collect(Collectors.joining(","))
                + "],\"settings\":" + settings.toJson() + "}");
        // Nothing in it is the caller's: shared caches may keep it.
        answer.setHeaders(Map.of("Content-Type", "application/json",
                "Cache-Control", "public, max-age=" + MAX_AGE));
        return answer;
    }
}
