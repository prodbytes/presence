package presence.auth;

import software.amazon.awssdk.services.dynamodb.model.AttributeValue;

import java.time.Instant;
import java.util.Map;

/** Reading and writing DynamoDB attributes the way every table here stores them. */
final class Attrs {

    private Attrs() {
    }

    /** A string attribute, or empty if it's missing or not a string. */
    static String text(Map<String, AttributeValue> item, String name) {
        var value = item == null ? null : item.get(name);
        return value == null || value.s() == null ? "" : value.s();
    }

    /** Epoch milliseconds (as stored), or the epoch if missing or malformed. */
    static Instant instant(AttributeValue value) {
        try {
            return Instant.ofEpochMilli(Long.parseLong(value.n()));
        } catch (NumberFormatException | NullPointerException e) {
            return Instant.EPOCH;
        }
    }

    /** A number attribute as an int, or 0 if missing or malformed. */
    static int number(AttributeValue value) {
        try {
            return Integer.parseInt(value.n());
        } catch (NumberFormatException | NullPointerException e) {
            return 0;
        }
    }

    /** {@code instant} as epoch milliseconds. */
    static AttributeValue millis(Instant instant) {
        return AttributeValue.fromN(Long.toString(instant.toEpochMilli()));
    }
}
