package presence.auth;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class Dinov2Test {

    /** The real model, when PRESENCE_TEST_MODEL names its file (1.2 GB; see specs/cloud-recognition.md). */
    @Test
    @EnabledIfEnvironmentVariable(named = "PRESENCE_TEST_MODEL", matches = ".+")
    void embeds() {
        var model = new Dinov2(Path.of(System.getenv("PRESENCE_TEST_MODEL")));
        var random = new Random(1);
        var stripes = new byte[Embedder.PIXELS];
        var shifted = new byte[Embedder.PIXELS];
        var noise = new byte[Embedder.PIXELS];
        for (var y = 0; y < Embedder.SIZE; y++) {
            for (var x = 0; x < Embedder.SIZE; x++) {
                for (var c = 0; c < 3; c++) {
                    var i = (y * Embedder.SIZE + x) * 3 + c;
                    stripes[i] = (byte) ((x / 16) % 2 == 0 ? 220 : 30);
                    shifted[i] = (byte) (((x + 2) / 16) % 2 == 0 ? 215 : 35);
                    noise[i] = (byte) random.nextInt(256);
                }
            }
        }
        var v = model.embed(List.of(stripes, shifted, noise));
        assertEquals(3, v.length);
        assertEquals(Embedder.DIMENSIONS, v[0].length);
        assertEquals(1, Math.sqrt(Vectors.dot(v[0], v[0])), 1e-3);
        var alike = Vectors.dot(v[0], v[1]);
        var unlike = Vectors.dot(v[0], v[2]);
        assertTrue(alike > unlike, "stripes nearer stripes (" + alike + ") than noise (" + unlike + ")");
    }

    @Test
    void aWrongFileIsRefused(@org.junit.jupiter.api.io.TempDir Path dir) throws Exception {
        var file = new ModelFile(new ModelFile.Source("dinov2-large", "http://unused", "00".repeat(32)), null, dir);
        var to = dir.resolve("x.part");
        assertFalse(file.save(new ByteArrayInputStream(new byte[]{1, 2, 3}), to));
        assertFalse(Files.exists(to), "deleted");
        var right = new ModelFile(new ModelFile.Source("dinov2-large", "http://unused",
                "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"), null, dir);
        assertTrue(right.save(new ByteArrayInputStream(new byte[]{1, 2, 3}), to));
        assertTrue(right.key().startsWith("models/dinov2-large-039058c6f2c0cb49"));
    }

    @Test
    void theBucketsCopyComesInPartsPutTogetherInOrder(@org.junit.jupiter.api.io.TempDir Path dir) throws Exception {
        // 3 MB and some, so each of the parts has bytes, some not a whole MB.
        var bytes = new byte[3 * (1 << 20) + 12345];
        new java.util.Random(7).nextBytes(bytes);
        var sha = ModelFile.sha256Of(new ByteArrayInputStream(bytes));
        var file = new ModelFile(new ModelFile.Source("dinov2-large", "http://unused", sha), null, dir);
        var asked = java.util.Collections.synchronizedList(new java.util.ArrayList<long[]>());
        var to = dir.resolve("x.part");
        assertTrue(file.fetchInParts(bytes.length, (start, end) -> {
            asked.add(new long[]{start, end});
            return new ByteArrayInputStream(bytes, (int) start, (int) (end - start + 1));
        }, to));
        assertEquals(ModelFile.PARTS, asked.size());
        assertArrayEquals(bytes, Files.readAllBytes(to));

        // A wrong copy is refused and deleted.
        var wrong = new ModelFile(new ModelFile.Source("dinov2-large", "http://unused", "00".repeat(32)), null, dir);
        assertFalse(wrong.fetchInParts(bytes.length,
                (start, end) -> new ByteArrayInputStream(bytes, (int) start, (int) (end - start + 1)), to));
        assertFalse(Files.exists(to));
    }
}
