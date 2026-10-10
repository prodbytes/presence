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
 * message, to everyone but admins. <b>rbacr decides it</b> ({@link Flag}):
 * the {@code presence} system's maintenance flag, and, when rbacr can't be
 * reached (or can't say), maintenance automatically, since nobody's roles
 * can be known then. Roots switch the flag ({@link AdminHandler}, or in
 * rbacr itself); {@code GET /api/auth/anonymous} tells every app
 * ({@link AuthHandler}).
 *
 * <p>This record is what presence keeps besides the flag ({@link Store}):
 * the last switch made here, with the sorry screen's message.
 *
 * @param on      whether that switch put the system in maintenance
 * @param message what the sorry screen says besides the default, or empty
 * @param since   when it was last switched here, or null if it never was
 * @param by      the root's email who switched it, or empty
 */
public record Maintenance(boolean on, String message, Instant since, String by) {

    /** The longest message an admin may leave. */
    static final int MAX_MESSAGE = 500;

    /** Never switched on. */
    static final Maintenance OFF = new Maintenance(false, "", null, "");

    /** Why the system is in maintenance, as {@code GET /api/auth/anonymous} says. */
    static final String SWITCHED = "rbacr";

    /** rbacr didn't answer (or couldn't say): maintenance until it does. */
    static final String UNREACHABLE = "rbacr-unreachable";

    /** The maintenance flag, from rbacr. */
    interface Flag {
        /** Whether the system is in maintenance; null when it can't be told (rbacr unreachable). */
        Boolean get();

        /** @throws IllegalStateException when it can't be switched */
        void set(boolean on);
    }

    /** rbacr's flag on its system ({@link Rbacr#maintenance}). */
    static Flag rbacr(Rbacr rbacr) {
        return new Flag() {
            @Override
            public Boolean get() {
                return rbacr.maintenance();
            }

            @Override
            public void set(boolean on) {
                rbacr.setMaintenance(on);
            }
        };
    }

    /** A flag in memory, off at first (tests, and handlers made without rbacr). */
    static Flag memoryFlag() {
        var flag = new AtomicReference<Boolean>(false);
        return new Flag() {
            @Override
            public Boolean get() {
                return flag.get();
            }

            @Override
            public void set(boolean on) {
                flag.set(on);
            }
        };
    }

    /**
     * The state every app is told: off, on (rbacr's flag, with the message
     * of the switch made here, if that one put it on) or on because rbacr
     * can't say.
     *
     * @param flag   rbacr's answer, null when it can't say
     * @param stored the last switch made here
     */
    static String publicJson(Boolean flag, Maintenance stored) {
        if (flag == null) {
            return new Maintenance(true, "", null, "").toPublicJson(UNREACHABLE);
        }
        if (!flag) {
            return OFF.toPublicJson(null);
        }
        // Switched on in rbacr itself, the message here is an older switch's.
        return (stored.on() ? stored : new Maintenance(true, "", null, "")).toPublicJson(SWITCHED);
    }

    /** Where the last switch made here is kept. */
    interface Store {
        /** The current state; {@link #OFF} if it was never set. */
        Maintenance get();

        void set(Maintenance state);
    }

    /**
     * As {@code GET /api/auth/anonymous} answers it, for anyone: without
     * who switched it. {@code {"on":true,"message":"...","since":<epoch ms>,
     * "reason":"rbacr"}}.
     *
     * @param reason why it's on ({@link #SWITCHED}, {@link #UNREACHABLE}), or null
     */
    String toPublicJson(String reason) {
        return "{\"on\":" + on + ",\"message\":" + Json.string(message)
                + (since == null ? "" : ",\"since\":" + since.toEpochMilli())
                + (reason == null ? "" : ",\"reason\":" + Json.string(reason)) + "}";
    }

    /**
     * As the admin routes answer it: whether the system is in maintenance
     * ({@code flag}, from rbacr: on when it can't say), with the last switch
     * made here and who made it, and whether rbacr answered
     * ({@code "rbacr": true}).
     */
    String toJson(Boolean flag) {
        var on = flag == null || flag;
        var json = new Maintenance(on, message, since, by).toPublicJson(
                flag == null ? UNREACHABLE : on ? SWITCHED : null);
        return json.substring(0, json.length() - 1) + ",\"by\":" + Json.string(by)
                + ",\"rbacr\":" + (flag != null) + "}";
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
