package presence.payments;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * A small, strict JSON reader for what the store purchases read: request
 * bodies, Apple's signed payloads and Google's answers. Objects become
 * {@link Map}s, arrays {@link List}s, numbers {@link BigDecimal}s, and
 * {@code true}, {@code false} and {@code null} themselves. Anything that
 * isn't one JSON value (trailing text, a duplicate key, nesting deeper than
 * {@link #MAX_DEPTH}) throws {@link IllegalArgumentException}.
 */
final class JsonReader {

    /** The deepest nesting taken. */
    static final int MAX_DEPTH = 32;

    private final String text;
    private int at;

    private JsonReader(String text) {
        this.text = text;
    }

    /** The value {@code text} holds. */
    static Object parse(String text) {
        if (text == null) {
            throw new IllegalArgumentException("no JSON");
        }
        var reader = new JsonReader(text);
        var value = reader.value(0);
        reader.space();
        if (reader.at != text.length()) {
            throw new IllegalArgumentException("text after the JSON value");
        }
        return value;
    }

    /** The object {@code text} holds; throws when it's another value. */
    @SuppressWarnings("unchecked")
    static Map<String, Object> object(String text) {
        if (parse(text) instanceof Map<?, ?> map) {
            return (Map<String, Object>) map;
        }
        throw new IllegalArgumentException("not a JSON object");
    }

    /** {@code map[key]} when it's a string, else null. */
    static String string(Map<String, Object> map, String key) {
        return map != null && map.get(key) instanceof String s ? s : null;
    }

    /** {@code map[key]} when it's a whole number, else null. */
    static Long number(Map<String, Object> map, String key) {
        if (map != null && map.get(key) instanceof BigDecimal n) {
            try {
                return n.longValueExact();
            } catch (ArithmeticException e) {
                return null;
            }
        }
        return null;
    }

    /** {@code map[key]} when it's an object, else null. */
    @SuppressWarnings("unchecked")
    static Map<String, Object> child(Map<String, Object> map, String key) {
        return map != null && map.get(key) instanceof Map<?, ?> m ? (Map<String, Object>) m : null;
    }

    /** {@code map[key]} when it's an array, else an empty list. */
    @SuppressWarnings("unchecked")
    static List<Object> list(Map<String, Object> map, String key) {
        return map != null && map.get(key) instanceof List<?> l ? (List<Object>) l : List.of();
    }

    private Object value(int depth) {
        if (depth > MAX_DEPTH) {
            throw new IllegalArgumentException("JSON nested too deep");
        }
        space();
        if (at >= text.length()) {
            throw new IllegalArgumentException("JSON ends early");
        }
        var c = text.charAt(at);
        return switch (c) {
            case '{' -> object(depth);
            case '[' -> array(depth);
            case '"' -> string();
            case 't' -> word("true", Boolean.TRUE);
            case 'f' -> word("false", Boolean.FALSE);
            case 'n' -> word("null", null);
            default -> {
                if (c == '-' || (c >= '0' && c <= '9')) {
                    yield number();
                }
                throw new IllegalArgumentException("unexpected '" + c + "' in JSON");
            }
        };
    }

    private Map<String, Object> object(int depth) {
        at++;
        var map = new LinkedHashMap<String, Object>();
        space();
        if (peek() == '}') {
            at++;
            return map;
        }
        while (true) {
            space();
            if (peek() != '"') {
                throw new IllegalArgumentException("a JSON key must be a string");
            }
            var key = string();
            space();
            expect(':');
            if (map.containsKey(key)) {
                throw new IllegalArgumentException("duplicate JSON key");
            }
            map.put(key, value(depth + 1));
            space();
            var c = next();
            if (c == '}') {
                return map;
            }
            if (c != ',') {
                throw new IllegalArgumentException("expected ',' or '}' in JSON");
            }
        }
    }

    private List<Object> array(int depth) {
        at++;
        var list = new ArrayList<>();
        space();
        if (peek() == ']') {
            at++;
            return list;
        }
        while (true) {
            list.add(value(depth + 1));
            space();
            var c = next();
            if (c == ']') {
                return list;
            }
            if (c != ',') {
                throw new IllegalArgumentException("expected ',' or ']' in JSON");
            }
        }
    }

    private String string() {
        at++;
        var out = new StringBuilder();
        while (true) {
            var c = next();
            if (c == '"') {
                return out.toString();
            }
            if (c < 0x20) {
                throw new IllegalArgumentException("control character in a JSON string");
            }
            if (c != '\\') {
                out.append(c);
                continue;
            }
            var e = next();
            switch (e) {
                case '"', '\\', '/' -> out.append(e);
                case 'b' -> out.append('\b');
                case 'f' -> out.append('\f');
                case 'n' -> out.append('\n');
                case 'r' -> out.append('\r');
                case 't' -> out.append('\t');
                case 'u' -> {
                    if (at + 4 > text.length()) {
                        throw new IllegalArgumentException("JSON ends early");
                    }
                    try {
                        out.append((char) Integer.parseInt(text.substring(at, at + 4), 16));
                    } catch (NumberFormatException x) {
                        throw new IllegalArgumentException("bad \\u escape in JSON");
                    }
                    at += 4;
                }
                default -> throw new IllegalArgumentException("bad escape in JSON");
            }
        }
    }

    private BigDecimal number() {
        var start = at;
        if (peek() == '-') {
            at++;
        }
        while (at < text.length() && "0123456789.eE+-".indexOf(text.charAt(at)) >= 0) {
            at++;
        }
        var literal = text.substring(start, at);
        if (literal.length() > 64 || !literal.matches("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?")) {
            throw new IllegalArgumentException("bad JSON number");
        }
        try {
            return new BigDecimal(literal);
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("bad JSON number");
        }
    }

    private Object word(String word, Object value) {
        if (!text.startsWith(word, at)) {
            throw new IllegalArgumentException("bad JSON literal");
        }
        at += word.length();
        return value;
    }

    private void space() {
        while (at < text.length() && " \t\r\n".indexOf(text.charAt(at)) >= 0) {
            at++;
        }
    }

    private char peek() {
        if (at >= text.length()) {
            throw new IllegalArgumentException("JSON ends early");
        }
        return text.charAt(at);
    }

    private char next() {
        var c = peek();
        at++;
        return c;
    }

    private void expect(char c) {
        if (next() != c) {
            throw new IllegalArgumentException("expected '" + c + "' in JSON");
        }
    }
}
