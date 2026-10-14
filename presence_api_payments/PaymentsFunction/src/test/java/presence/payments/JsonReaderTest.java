package presence.payments;

import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

class JsonReaderTest {

    @Test
    void readsJson() {
        var map = JsonReader.object(" {\"a\": \"x\\\"\\u00e9\\n\", \"n\": -12, \"f\": 1.5e2, \"t\": true,"
                + " \"z\": null, \"l\": [1, {\"b\": []}], \"o\": {}} ");
        assertEquals("x\"\u00e9\n", JsonReader.string(map, "a"));
        assertEquals(-12L, JsonReader.number(map, "n"));
        assertEquals(new BigDecimal("1.5e2"), map.get("f"));
        assertEquals(Boolean.TRUE, map.get("t"));
        assertNull(map.get("z"));
        assertEquals(2, JsonReader.list(map, "l").size());
        assertEquals(Map.of(), JsonReader.child(map, "o"));
        assertNull(JsonReader.string(map, "n"));
        assertEquals(150L, JsonReader.number(map, "f"));
        assertEquals(List.of(), JsonReader.list(map, "missing"));
    }

    @Test
    void refusesWhatIsntOneJsonValue() {
        for (var bad : new String[]{"", "{", "{\"a\":1,}", "{\"a\":1}x", "{\"a\":1,\"a\":2}", "[1 2]", "01",
                "\"\u0001\"", "{a:1}", "tru", "\"\\x\"", "1e99999999999", "[".repeat(100) + "]".repeat(100)}) {
            assertThrows(IllegalArgumentException.class, () -> JsonReader.parse(bad), bad);
        }
        assertThrows(IllegalArgumentException.class, () -> JsonReader.object("[]"));
    }
}
