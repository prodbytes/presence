package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import org.junit.jupiter.api.Test;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class FeedbackTest {

    private static final Instant NOW = Instant.parse("2026-10-10T12:00:00Z");

    /** The feedback table: unique by (email, sentAt). */
    private final List<FeedbackHandler.Message> messages = new ArrayList<>();
    private final Map<String, Set<String>> declared = new HashMap<>(Map.of(
            "ana@example.com", Set.of(Roles.USER),
            "bob@example.com", Set.of(Roles.USER)));

    /** A clock the tests move. */
    private Instant now = NOW;

    private final FeedbackHandler feedback = new FeedbackHandler(
            new Roles(Set.of("nu01.com"), Set.of(), e -> declared.getOrDefault(e, Set.of())),
            subject -> null,
            new FeedbackHandler.Store() {
                @Override
                public List<FeedbackHandler.Message> thread(String email) {
                    return messages.stream().filter(m -> m.email().equals(email)).toList();
                }

                @Override
                public List<FeedbackHandler.Message> all() {
                    return List.copyOf(messages);
                }

                @Override
                public boolean add(FeedbackHandler.Message message) {
                    if (messages.stream().anyMatch(m -> m.email().equals(message.email())
                            && m.sentAt().equals(message.sentAt()))) {
                        return false;
                    }
                    return messages.add(message);
                }
            },
            new Clock() {
                @Override
                public ZoneId getZone() {
                    return ZoneOffset.UTC;
                }

                @Override
                public Clock withZone(ZoneId zone) {
                    return this;
                }

                @Override
                public Instant instant() {
                    return now;
                }
            });

    @Test
    void aMemberSendsAndReadsTheirConversation() {
        var sent = feedback.handleRequest(route("POST /api/auth/feedback", "ana@example.com", "  How do I \"flip\"?  "),
                null);
        assertEquals(201, sent.getStatusCode());
        assertEquals("{\"from\":\"user\",\"message\":\"How do I \\\"flip\\\"?\",\"sentAt\":\"2026-10-10T12:00:00Z\"}",
                sent.getBody());
        assertEquals("Ana", messages.getFirst().name());

        var list = feedback.handleRequest(route("GET /api/auth/feedback", "ana@example.com", null), null);
        assertEquals(200, list.getStatusCode());
        assertEquals("{\"messages\":[{\"from\":\"user\",\"message\":\"How do I \\\"flip\\\"?\","
                + "\"sentAt\":\"2026-10-10T12:00:00Z\"}]}", list.getBody());

        // Others' conversations aren't theirs.
        assertEquals("{\"messages\":[]}", feedback.handleRequest(
                route("GET /api/auth/feedback", "bob@example.com", null), null).getBody());
    }

    @Test
    void onlyMembersSendFeedback() {
        assertEquals(403, feedback.handleRequest(
                route("POST /api/auth/feedback", "eve@example.com", "hi"), null).getStatusCode());
        assertEquals(403, feedback.handleRequest(
                route("GET /api/auth/feedback", "eve@example.com", null), null).getStatusCode());
        var unverified = route("POST /api/auth/feedback", "ana@example.com", "hi");
        unverified.getRequestContext().getAuthorizer().getJwt().getClaims().put("email_verified", "false");
        assertEquals(403, feedback.handleRequest(unverified, null).getStatusCode());
        assertEquals(403, feedback.handleRequest(new APIGatewayV2HTTPEvent(), null).getStatusCode());
        assertEquals(List.of(), messages);
    }

    @Test
    void messagesAreNeitherEmptyNorLong() {
        assertEquals(400, feedback.handleRequest(
                route("POST /api/auth/feedback", "ana@example.com", "   "), null).getStatusCode());
        assertEquals(400, feedback.handleRequest(route("POST /api/auth/feedback", "ana@example.com",
                "x".repeat(FeedbackHandler.MAX_MESSAGE + 1)), null).getStatusCode());
        assertEquals(201, feedback.handleRequest(route("POST /api/auth/feedback", "ana@example.com",
                "x".repeat(FeedbackHandler.MAX_MESSAGE)), null).getStatusCode());
    }

    @Test
    void aMemberSendsAtMostTheDailyLimit() {
        for (var i = 0; i < FeedbackHandler.DAILY_LIMIT; i++) {
            // Two in the same millisecond each get their own (the next one).
            assertEquals(201, feedback.handleRequest(
                    route("POST /api/auth/feedback", "ana@example.com", "m" + i), null).getStatusCode());
            now = now.plusMillis(i % 2 * 10);
        }
        assertEquals(409, feedback.handleRequest(
                route("POST /api/auth/feedback", "ana@example.com", "one more"), null).getStatusCode());
        // Replies don't count, and the day passes.
        now = NOW.plus(FeedbackHandler.DAY).plusSeconds(1);
        assertEquals(201, feedback.handleRequest(
                route("POST /api/auth/feedback", "ana@example.com", "next day"), null).getStatusCode());
        assertEquals(FeedbackHandler.DAILY_LIMIT + 1, messages.size());
    }

    @Test
    void onlyAdminsListAndReply() {
        feedback.handleRequest(route("POST /api/auth/feedback", "ana@example.com", "hi"), null);
        assertEquals(403, feedback.handleRequest(
                route("GET /api/auth/feedback/threads", "bob@example.com", null), null).getStatusCode());
        assertEquals(403, feedback.handleRequest(
                route("POST /api/auth/feedback/reply", "bob@example.com", reply("ana@example.com", "no")), null)
                .getStatusCode());
        // presence_admin without presence_user isn't enough.
        declared.put("half@example.com", Set.of(Roles.ADMIN));
        assertEquals(403, feedback.handleRequest(
                route("GET /api/auth/feedback/threads", "half@example.com", null), null).getStatusCode());
        assertEquals(1, messages.size());
    }

    @Test
    void anAdminListsConversationsAndReplies() {
        feedback.handleRequest(route("POST /api/auth/feedback", "ana@example.com", "first"), null);
        now = now.plusSeconds(60);
        feedback.handleRequest(route("POST /api/auth/feedback", "bob@example.com", "second"), null);
        now = now.plusSeconds(60);

        var replied = feedback.handleRequest(
                route("POST /api/auth/feedback/reply", "boss@nu01.com", reply(" ANA@example.com ", " Thanks! ")), null);
        assertEquals(201, replied.getStatusCode());
        assertEquals("{\"from\":\"admin\",\"message\":\"Thanks!\",\"sentAt\":\"2026-10-10T12:02:00Z\"}",
                replied.getBody());

        var threads = feedback.handleRequest(route("GET /api/auth/feedback/threads", "boss@nu01.com", null), null);
        assertEquals(200, threads.getStatusCode());
        // Ana's, answered last, first; the admin who replied is named.
        assertEquals("{\"threads\":["
                + "{\"email\":\"ana@example.com\",\"name\":\"Ana\",\"messages\":["
                + "{\"from\":\"user\",\"by\":\"\",\"message\":\"first\",\"sentAt\":\"2026-10-10T12:00:00Z\"},"
                + "{\"from\":\"admin\",\"by\":\"boss@nu01.com\",\"message\":\"Thanks!\","
                + "\"sentAt\":\"2026-10-10T12:02:00Z\"}]},"
                + "{\"email\":\"bob@example.com\",\"name\":\"Ana\",\"messages\":["
                + "{\"from\":\"user\",\"by\":\"\",\"message\":\"second\",\"sentAt\":\"2026-10-10T12:01:00Z\"}]}"
                + "]}", threads.getBody());

        // The member sees the reply, without the admin's email.
        var mine = feedback.handleRequest(route("GET /api/auth/feedback", "ana@example.com", null), null).getBody();
        assertTrue(mine.endsWith("{\"from\":\"admin\",\"message\":\"Thanks!\",\"sentAt\":\"2026-10-10T12:02:00Z\"}]}"));
    }

    @Test
    void repliesNeedAConversationAnEmailAndAMessage() {
        assertEquals(404, feedback.handleRequest(
                route("POST /api/auth/feedback/reply", "boss@nu01.com", reply("nobody@example.com", "hi")), null)
                .getStatusCode());
        feedback.handleRequest(route("POST /api/auth/feedback", "ana@example.com", "hi"), null);
        assertEquals(400, feedback.handleRequest(
                route("POST /api/auth/feedback/reply", "boss@nu01.com", reply("not an email", "hi")), null)
                .getStatusCode());
        assertEquals(400, feedback.handleRequest(
                route("POST /api/auth/feedback/reply", "boss@nu01.com", reply("ana@example.com", " ")), null)
                .getStatusCode());
        assertEquals(400, feedback.handleRequest(route("POST /api/auth/feedback/reply", "boss@nu01.com",
                reply("ana@example.com", "x".repeat(FeedbackHandler.MAX_MESSAGE + 1))), null).getStatusCode());
        assertEquals(1, messages.size());
    }

    @Test
    void unknownRoutesAnswer404() {
        assertEquals(404, feedback.handleRequest(
                route("DELETE /api/auth/feedback", "ana@example.com", null), null).getStatusCode());
    }

    private static String reply(String email, String message) {
        return "email=" + URLEncoder.encode(email, StandardCharsets.UTF_8)
                + "&message=" + URLEncoder.encode(message, StandardCharsets.UTF_8);
    }

    private static APIGatewayV2HTTPEvent route(String routeKey, String email, String body) {
        var event = RolesTest.event(RolesTest.verified(email));
        event.setRouteKey(routeKey);
        event.setBody(body);
        return event;
    }
}
