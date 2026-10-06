package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

import static presence.auth.Http.response;

/**
 * {@code POST /api/auth/membership}: a signed-in user without access asks for
 * it. The body is their message, as plain text. The request is kept in the
 * membership table (one per email; a new one replaces the last only after
 * {@link #COOLDOWN}, even if the last was dismissed), where the Admin
 * screen lists it. The HTTP API's JWT authorizer has already verified the
 * Google ID token ({@link Caller}).
 */
public class MembershipHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** The longest message kept, in characters. */
    static final int MAX_MESSAGE = 1000;

    /** A user may ask again only after this long. */
    static final Duration COOLDOWN = Duration.ofHours(1);

    /** A membership request, as stored and listed. */
    record Request(String email, String name, String message, Instant requestedAt) {
    }

    interface Store {
        /** Saves {@code request}, unless the same email's last request is newer than {@code cutoff}. */
        boolean save(Request request, Instant cutoff);
    }

    private final Store store;
    private final Clock clock;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public MembershipHandler() {
        this(dynamoStore(System.getenv("MEMBERSHIP_TABLE")), Clock.systemUTC());
    }

    MembershipHandler(Store store, Clock clock) {
        this.store = store;
        this.clock = clock;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var caller = Caller.from(event);
        var email = caller.verifiedEmail();
        if (email == null) {
            return response(403, "{\"error\":\"a verified email is required\"}");
        }
        var message = Http.bodyText(event, MAX_MESSAGE);
        if (message == null) {
            return response(400, "{\"error\":\"the message is longer than " + MAX_MESSAGE + " characters\"}");
        }
        if (message.isEmpty()) {
            return response(400, "{\"error\":\"the message is empty\"}");
        }
        var now = clock.instant();
        var request = new Request(email, cleanName(caller.claims().get("name")), message, now);
        try {
            if (!store.save(request, now.minus(COOLDOWN))) {
                // 409, not 429: API Gateway's throttling answers 429.
                return response(409, "{\"error\":\"a request was already sent; try again later\"}");
            }
        } catch (RuntimeException e) {
            return Aws.failed("membership", Http.route(event), e, context);
        }
        return response(202, "{\"requestedAt\":" + Json.string(now.toString()) + "}");
    }

    /** The Google profile name, which its owner chooses: one line, no control characters, 100 at most. */
    static String cleanName(String name) {
        if (name == null) {
            return "";
        }
        var clean = name.replaceAll("\\p{Cntrl}", " ").strip();
        return clean.length() > 100 ? clean.substring(0, 100) : clean;
    }

    /** One item per email; a new request replaces the last only once the cooldown has passed. */
    static Store dynamoStore(String table) {
        var dynamo = Aws.dynamo();
        return (request, cutoff) -> {
            var item = new HashMap<String, AttributeValue>();
            item.put("email", AttributeValue.fromS(request.email()));
            item.put("message", AttributeValue.fromS(request.message()));
            item.put("requestedAt", AttributeValue.fromN(Long.toString(request.requestedAt().toEpochMilli())));
            if (!request.name().isEmpty()) {
                item.put("name", AttributeValue.fromS(request.name()));
            }
            try {
                dynamo.putItem(PutItemRequest.builder()
                        .tableName(table)
                        .item(item)
                        .conditionExpression("attribute_not_exists(email) OR requestedAt < :cutoff")
                        .expressionAttributeValues(Map.of(
                                ":cutoff", AttributeValue.fromN(Long.toString(cutoff.toEpochMilli()))))
                        .build());
                return true;
            } catch (ConditionalCheckFailedException e) {
                return false;
            }
        };
    }
}
