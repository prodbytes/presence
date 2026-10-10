package presence.auth;

import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.GetItemRequest;
import software.amazon.awssdk.services.dynamodb.model.PutItemRequest;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static presence.auth.Attrs.instant;
import static presence.auth.Attrs.millis;
import static presence.auth.Attrs.text;

/**
 * Maintenance mode: while it's on, the app shows nothing but a sorry
 * message, to everyone but admins. Admins switch it on and off
 * ({@link AdminHandler}); {@code GET /api/auth/anonymous} tells every app
 * ({@link AuthHandler}).
 *
 * @param on      whether the system is in maintenance
 * @param message what the sorry screen says besides the default, or empty
 * @param since   when it was last switched, or null if it never was
 * @param by      the admin's email who switched it, or empty
 */
public record Maintenance(boolean on, String message, Instant since, String by) {

    /** The longest message an admin may leave. */
    static final int MAX_MESSAGE = 500;

    /** Never switched on. */
    static final Maintenance OFF = new Maintenance(false, "", null, "");

    /** Where the state is kept. */
    interface Store {
        /** The current state; {@link #OFF} if it was never set. */
        Maintenance get();

        void set(Maintenance state);
    }

    /**
     * As {@code GET /api/auth/anonymous} answers it, for anyone: without
     * who switched it. {@code {"on":true,"message":"...","since":<epoch ms>}}.
     */
    String toPublicJson() {
        return "{\"on\":" + on + ",\"message\":" + Json.string(message)
                + (since == null ? "" : ",\"since\":" + since.toEpochMilli()) + "}";
    }

    /** As the admin routes answer it: also who switched it. */
    String toJson() {
        var json = toPublicJson();
        return json.substring(0, json.length() - 1) + ",\"by\":" + Json.string(by) + "}";
    }

    /**
     * {@code message} trimmed, with control characters other than line
     * breaks dropped; null if it's longer than {@link #MAX_MESSAGE}.
     */
    static String cleanMessage(String message) {
        if (message == null) {
            return "";
        }
        var out = new StringBuilder();
        message.strip().codePoints()
                .filter(c -> c == '\n' || !Character.isISOControl(c))
                .forEach(out::appendCodePoint);
        return out.length() > MAX_MESSAGE ? null : out.toString();
    }

    /** In memory (tests, and handlers made without a table). */
    static Store memory() {
        var state = new AtomicReference<>(OFF);
        return new Store() {
            @Override
            public Maintenance get() {
                return state.get();
            }

            @Override
            public void set(Maintenance next) {
                state.set(next);
            }
        };
    }

    /**
     * One item, {@code {"id": "maintenance", "on", "message", "since"
     * (epoch ms), "by"}}, in {@code table}. Without a table, always off.
     */
    static Store dynamoStore(String table) {
        if (table == null || table.isBlank()) {
            return new Store() {
                @Override
                public Maintenance get() {
                    return OFF;
                }

                @Override
                public void set(Maintenance state) {
                    throw new IllegalStateException("no SYSTEM_TABLE to keep maintenance mode in");
                }
            };
        }
        var dynamo = Aws.dynamo();
        var key = Map.of("id", AttributeValue.fromS("maintenance"));
        return new Store() {
            @Override
            public Maintenance get() {
                var item = dynamo.getItem(GetItemRequest.builder()
                        .tableName(table).key(key).consistentRead(true).build()).item();
                if (item == null || item.isEmpty()) {
                    return OFF;
                }
                var on = item.get("on");
                return new Maintenance(on != null && Boolean.TRUE.equals(on.bool()), text(item, "message"),
                        item.containsKey("since") ? instant(item.get("since")) : null, text(item, "by"));
            }

            @Override
            public void set(Maintenance state) {
                var item = new HashMap<>(key);
                item.put("on", AttributeValue.fromBool(state.on()));
                item.put("message", AttributeValue.fromS(state.message()));
                item.put("by", AttributeValue.fromS(state.by()));
                if (state.since() != null) {
                    item.put("since", millis(state.since()));
                }
                dynamo.putItem(PutItemRequest.builder().tableName(table).item(item).build());
            }
        };
    }
}
