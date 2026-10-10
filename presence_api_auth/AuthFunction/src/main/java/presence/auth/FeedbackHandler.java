package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;
import software.amazon.awssdk.services.dynamodb.model.QueryRequest;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Function;
import java.util.stream.Collectors;

import static presence.auth.Attrs.instant;
import static presence.auth.Attrs.text;
import static presence.auth.Http.response;

/**
 * Feedback and Help: each member has one conversation with the
 * administrators, kept by email in the feedback table.
 * <ul>
 *   <li>{@code GET /api/auth/feedback}: the caller's conversation, oldest
 *       first, as {@code {"messages": [{from, message, sentAt}]}}, where
 *       {@code from} is {@code "user"} or {@code "admin"} (which admin
 *       isn't said);</li>
 *   <li>{@code POST /api/auth/feedback}: adds the (plain-text) body to it,
 *       at most {@link #MAX_MESSAGE} characters, and at most
 *       {@link #DAILY_LIMIT} messages a day (409 past that);</li>
 * </ul>
 * for users with {@code presence_user} (403 otherwise; a linked account
 * shares its owner's membership, and writes under its own email), and for
 * administrators ({@code presence_user} and {@code presence_admin}, as the
 * Admin routes):
 * <ul>
 *   <li>{@code GET /api/auth/feedback/threads}: every conversation, the
 *       latest active first, as {@code {"threads": [{email, name, messages:
 *       [{from, by, message, sentAt}]}]}}, {@code by} being the replying
 *       admin's email;</li>
 *   <li>{@code POST /api/auth/feedback/reply}: adds the form-encoded
 *       {@code message} to {@code email}'s conversation (404 if it has none:
 *       admins answer, they don't start conversations).</li>
 * </ul>
 */
public class FeedbackHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** The longest message kept, in characters. */
    static final int MAX_MESSAGE = 2000;

    /** How many messages a user may send in a {@link #DAY}. */
    static final int DAILY_LIMIT = 20;

    static final Duration DAY = Duration.ofDays(1);

    static final String USER = "user";
    static final String ADMIN = "admin";

    /**
     * One message of {@code email}'s conversation.
     *
     * @param name the user's Google profile name when they sent it, else empty
     * @param from {@link #USER} or {@link #ADMIN}
     * @param by   the admin's email for a reply, else empty
     */
    record Message(String email, String name, String from, String by, String message, Instant sentAt) {
    }

    interface Store {
        /** {@code email}'s conversation, in any order. */
        List<Message> thread(String email);

        /** Every message, in any order. */
        List<Message> all();

        /** Saves {@code message}, unless one of its conversation has the same time. */
        boolean add(Message message);
    }

    private final Roles roles;
    private final Function<String, Profiles.Profile> linked;
    private final Store store;
    private final Clock clock;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public FeedbackHandler() {
        this(Roles.fromEnvironment(), Profiles.fromEnvironment()::existing,
                dynamoStore(System.getenv("FEEDBACK_TABLE")),
                Clock.systemUTC());
    }

    /**
     * @param linked for a subject, the profile it's linked to, without making one
     *               ({@link Profiles#existing}): a linked subject shares the owner's membership
     */
    FeedbackHandler(Roles roles, Function<String, Profiles.Profile> linked, Store store, Clock clock) {
        this.roles = roles;
        this.linked = linked;
        this.store = store;
        this.clock = clock;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var route = Http.route(event);
        try {
            return handle(event, route);
        } catch (RuntimeException e) {
            return Aws.failed("feedback", route, e, context);
        }
    }

    private APIGatewayV2HTTPResponse handle(APIGatewayV2HTTPEvent event, String route) {
        var caller = Caller.from(event);
        var callerRoles = roles.of(caller, caller.hasSubject() ? linked.apply(caller.subject()) : null);
        // Roles need a verified email, so a member has one.
        var email = caller.verifiedEmail();
        if (!callerRoles.contains(Roles.USER) || email == null) {
            return response(403, "{\"error\":\"members only\"}");
        }
        var admin = callerRoles.contains(Roles.ADMIN);
        return switch (route) {
            case "GET /api/auth/feedback" -> response(200, "{\"messages\":["
                    + sorted(store.thread(email)).stream()
                    .map(m -> json(m, false))
                    .collect(Collectors.joining(","))
                    + "]}");
            case "POST /api/auth/feedback" -> send(event, email, caller);
            case "GET /api/auth/feedback/threads" -> admin
                    ? response(200, threads())
                    : response(403, "{\"error\":\"administrators only\"}");
            case "POST /api/auth/feedback/reply" -> admin
                    ? reply(event, email)
                    : response(403, "{\"error\":\"administrators only\"}");
            default -> response(404, "{\"error\":\"no such route\"}");
        };
    }

    private APIGatewayV2HTTPResponse send(APIGatewayV2HTTPEvent event, String email, Caller caller) {
        var text = Http.bodyText(event, MAX_MESSAGE);
        var invalid = invalid(text);
        if (invalid != null) {
            return invalid;
        }
        var since = clock.instant().minus(DAY);
        var today = store.thread(email).stream()
                .filter(m -> USER.equals(m.from()) && m.sentAt().isAfter(since))
                .count();
        if (today >= DAILY_LIMIT) {
            // 409, not 429: API Gateway's throttling answers 429.
            return response(409, "{\"error\":\"at most " + DAILY_LIMIT + " messages a day; try again later\"}");
        }
        return save(new Message(email, MembershipHandler.cleanName(caller.claims().get("name")), USER, "", text,
                clock.instant()));
    }

    private APIGatewayV2HTTPResponse reply(APIGatewayV2HTTPEvent event, String adminEmail) {
        var body = Http.bodyText(event, 8 * MAX_MESSAGE);
        var form = VoucherHandler.form(body == null ? "" : body);
        var email = form.getOrDefault("email", "").strip().toLowerCase(Locale.ROOT);
        if (!AdminHandler.validEmail(email)) {
            return response(400, "{\"error\":\"email must be an email\"}");
        }
        var text = form.getOrDefault("message", "").strip();
        var invalid = invalid(text.length() > MAX_MESSAGE ? null : text);
        if (invalid != null) {
            return invalid;
        }
        if (store.thread(email).isEmpty()) {
            return response(404, "{\"error\":\"no conversation with that email\"}");
        }
        return save(new Message(email, "", ADMIN, adminEmail, text, clock.instant()));
    }

    private static APIGatewayV2HTTPResponse invalid(String text) {
        if (text == null) {
            return response(400, "{\"error\":\"the message is longer than " + MAX_MESSAGE + " characters\"}");
        }
        if (text.isEmpty()) {
            return response(400, "{\"error\":\"the message is empty\"}");
        }
        return null;
    }

    /** Saves {@code message}; one sent in the same millisecond as another takes the next one. */
    private APIGatewayV2HTTPResponse save(Message message) {
        var at = message.sentAt().truncatedTo(ChronoUnit.MILLIS);
        for (var attempt = 0; attempt < 5; attempt++, at = at.plusMillis(1)) {
            var saved = new Message(message.email(), message.name(), message.from(), message.by(),
                    message.message(), at);
            if (store.add(saved)) {
                return response(201, json(saved, false));
            }
        }
        return response(409, "{\"error\":\"too many messages at once; try again\"}");
    }

    private String threads() {
        var byEmail = new LinkedHashMap<String, List<Message>>();
        for (var m : sorted(store.all())) {
            byEmail.computeIfAbsent(m.email(), e -> new ArrayList<>()).add(m);
        }
        return "{\"threads\":["
                + byEmail.values().stream()
                // The latest active first.
                .sorted(Comparator.comparing((List<Message> t) -> t.getLast().sentAt()).reversed())
                .map(FeedbackHandler::threadJson)
                .collect(Collectors.joining(","))
                + "]}";
    }

    private static String threadJson(List<Message> thread) {
        // The name it last sent with.
        var name = thread.reversed().stream().map(Message::name).filter(n -> !n.isEmpty()).findFirst().orElse("");
        return "{\"email\":" + Json.string(thread.getFirst().email())
                + ",\"name\":" + Json.string(name)
                + ",\"messages\":["
                + thread.stream().map(m -> json(m, true)).collect(Collectors.joining(","))
                + "]}";
    }

    private static List<Message> sorted(List<Message> messages) {
        return messages.stream().sorted(Comparator.comparing(Message::sentAt)).toList();
    }

    /** A message; {@code withAdmin} says which admin replied (admins only). */
    static String json(Message m, boolean withAdmin) {
        return "{\"from\":" + Json.string(m.from())
                + (withAdmin ? ",\"by\":" + Json.string(m.by()) : "")
                + ",\"message\":" + Json.string(m.message())
                + ",\"sentAt\":" + Json.string(m.sentAt().toString()) + "}";
    }

    /** Items {email, sentAt (epoch ms, the sort key), from, by?, name?, message}. */
    static Store dynamoStore(String table) {
        var dynamo = Aws.dynamo();
        Function<Map<String, AttributeValue>, Message> message = item -> new Message(
                text(item, "email"), text(item, "name"), text(item, "from"), text(item, "by"),
                text(item, "message"), instant(item.getOrDefault("sentAt", AttributeValue.fromN("0"))));
        return new Store() {
            @Override
            public List<Message> thread(String email) {
                var result = new ArrayList<Message>();
                var query = QueryRequest.builder()
                        .tableName(table)
                        .keyConditionExpression("email = :email")
                        .expressionAttributeValues(Map.of(":email", AttributeValue.fromS(email)))
                        .build();
                for (var page : dynamo.queryPaginator(query)) {
                    page.items().forEach(item -> result.add(message.apply(item)));
                }
                return result;
            }

            @Override
            public List<Message> all() {
                var result = new ArrayList<Message>();
                for (var page : dynamo.scanPaginator(ScanRequest.builder().tableName(table).build())) {
                    page.items().forEach(item -> result.add(message.apply(item)));
                }
                return result;
            }

            @Override
            public boolean add(Message m) {
                var item = new HashMap<String, AttributeValue>();
                item.put("email", AttributeValue.fromS(m.email()));
                item.put("sentAt", Attrs.millis(m.sentAt()));
                item.put("from", AttributeValue.fromS(m.from()));
                item.put("message", AttributeValue.fromS(m.message()));
                if (!m.by().isEmpty()) {
                    item.put("by", AttributeValue.fromS(m.by()));
                }
                if (!m.name().isEmpty()) {
                    item.put("name", AttributeValue.fromS(m.name()));
                }
                try {
                    dynamo.putItem(PutItemRequest.builder()
                            .tableName(table)
                            .item(item)
                            .conditionExpression("attribute_not_exists(sentAt)")
                            .build());
                    return true;
                } catch (ConditionalCheckFailedException e) {
                    return false;
                }
            }
        };
    }
}
