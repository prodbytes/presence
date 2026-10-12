package presence.auth;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import javax.imageio.ImageIO;
import java.io.IOException;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static presence.auth.RecognitionTest.crop;
import static presence.auth.RecognitionTest.json;
import static presence.auth.RecognitionTest.request;

class DescribeTest {

    /** Each crop's color (its first pixel's red) picks a label: its text embedding, so it's that label surely. */
    static final class FakeEmbedder implements Embedder {
        final AtomicInteger crops = new AtomicInteger();

        @Override
        public float[][] embed(List<byte[]> pixels) {
            var out = new float[pixels.size()][];
            for (var i = 0; i < pixels.size(); i++) {
                crops.incrementAndGet();
                out[i] = PetLabels.LABELS.get(pixels.get(i)[0] & 0xff).vector().clone();
            }
            return out;
        }
    }

    final FakeEmbedder embedder = new FakeEmbedder();
    boolean premium = true;
    final DescribeHandler handler = new DescribeHandler(
            caller -> new RecognitionApi.Access("brave_quiet_otter", premium), () -> embedder);

    static int index(String label) {
        for (var i = 0; i < PetLabels.LABELS.size(); i++) {
            if (PetLabels.LABELS.get(i).label().equals(label)) {
                return i;
            }
        }
        throw new IllegalArgumentException(label);
    }

    Map<String, Object> describe(Object crops) throws IOException {
        var answer = handler.handleRequest(request("POST /api/recognition/describe", Map.of("crops", crops), true),
                null);
        assertEquals(200, answer.getStatusCode(), answer.getBody());
        return json(answer);
    }

    @Test
    void theLabelsLoad() {
        var cats = PetLabels.LABELS.stream().filter(l -> l.species().equals("cat")).count();
        var dogs = PetLabels.LABELS.stream().filter(l -> l.species().equals("dog")).count();
        assertTrue(cats > 30 && dogs > 70, cats + " cat and " + dogs + " dog labels");
        for (var l : PetLabels.LABELS) {
            assertEquals(1, Math.sqrt(Vectors.dot(l.vector(), l.vector())), 1e-3, l.label());
            assertTrue(List.of("breed", "coat", "none").contains(l.type()), l.type());
        }
    }

    @Test
    void premiumOnly() throws IOException {
        premium = false;
        var answer = handler.handleRequest(request("POST /api/recognition/describe",
                Map.of("crops", List.of(Map.of("id", "a", "kind", "cat", "pixels", crop(0, 1)))), true), null);
        assertEquals(403, answer.getStatusCode());
        premium = true;
        answer = handler.handleRequest(request("POST /api/recognition/describe",
                Map.of("crops", List.of(Map.of("id", "a", "kind", "cat", "pixels", crop(0, 1)))), false), null);
        assertEquals(403, answer.getStatusCode(), "an unverified email");
        assertEquals(0, embedder.crops.get());
    }

    @Test
    void badCropsAreRefused() throws IOException {
        var tooMany = new ArrayList<Map<String, Object>>();
        for (var i = 0; i < 9; i++) {
            tooMany.add(Map.of("id", "c" + i, "kind", "cat", "pixels", crop(0, i)));
        }
        for (var body : List.<Object>of(tooMany, List.of(),
                List.of(Map.of("id", "a", "kind", "person", "pixels", crop(0, 1))),
                List.of(Map.of("id", "a", "kind", "pet", "pixels", crop(0, 1))),
                List.of(Map.of("id", "a", "kind", "cat", "pixels", "AAAA")),
                List.of(Map.of("kind", "cat", "pixels", crop(0, 1))))) {
            assertEquals(400, handler.handleRequest(request("POST /api/recognition/describe",
                    Map.of("crops", body), true), null).getStatusCode(), String.valueOf(body).lines().findFirst().orElse(""));
        }
        assertEquals(404, handler.handleRequest(request("POST /api/recognition/identify",
                Map.of("crops", List.of()), true), null).getStatusCode());
        assertEquals(0, embedder.crops.get());
    }

    @Test
    void namesBreedsAndCoats() throws IOException {
        var answer = describe(List.of(
                Map.of("id", "persian", "kind", "cat", "pixels", crop(index("Persian"), 1)),
                Map.of("id", "black", "kind", "cat", "pixels", crop(index("black cat"), 2)),
                Map.of("id", "lab", "kind", "dog", "pixels", crop(index("Labrador Retriever"), 3)),
                Map.of("id", "house", "kind", "cat", "pixels", crop(index("Domestic Shorthair"), 4)),
                Map.of("id", "bombay", "kind", "cat", "pixels", crop(index("Bombay"), 5))));
        assertEquals("siglip2-base-patch16-224", answer.get("model"));
        var results = (List<?>) answer.get("results");
        assertEquals(5, results.size());
        var byId = new java.util.HashMap<String, List<String>>();
        for (var r : results) {
            var m = (Map<?, ?>) r;
            byId.put((String) m.get("id"), ((List<?>) m.get("labels")).stream()
                    .map(l -> ((Map<?, ?>) l).get("label") + "/" + ((Map<?, ?>) l).get("type")).toList());
        }
        assertTrue(byId.get("persian").contains("Persian/breed"), byId.get("persian").toString());
        assertTrue(byId.get("black").contains("black cat/coat"), byId.get("black").toString());
        assertTrue(byId.get("lab").contains("Labrador Retriever/breed"), byId.get("lab").toString());
        assertTrue(byId.get("house").stream().noneMatch(l -> l.endsWith("/breed")), "a house cat: no breed");
        assertTrue(byId.get("bombay").stream().noneMatch(l -> l.endsWith("/breed")), "a Bombay: no breed");
        for (var r : results) {
            for (var l : (List<?>) ((Map<?, ?>) r).get("labels")) {
                var c = ((Number) ((Map<?, ?>) l).get("confidence")).doubleValue();
                assertTrue(c >= PetLabels.COAT_SURE && c <= 1, "confidence " + c);
            }
        }
    }

    @Test
    void aCatIsNeverGivenADogsLabels() throws IOException {
        var answer = describe(List.of(Map.of("id", "a", "kind", "cat", "pixels",
                crop(index("Labrador Retriever"), 1))));
        var labels = (List<?>) ((Map<?, ?>) ((List<?>) answer.get("results")).get(0)).get("labels");
        for (var l : labels) {
            var label = (String) ((Map<?, ?>) l).get("label");
            assertTrue(PetLabels.LABELS.stream().anyMatch(x -> x.label().equals(label) && x.species().equals("cat")),
                    label);
        }
    }

    /**
     * The real model, when PRESENCE_TEST_SIGLIP2 names its file (95 MB) and
     * PRESENCE_TEST_PET a picture of a black cat (cropped around her, any
     * size): she's a black cat.
     */
    @Test
    @EnabledIfEnvironmentVariable(named = "PRESENCE_TEST_SIGLIP2", matches = ".+")
    void aBlackCat() throws IOException {
        var model = new Siglip2(Path.of(System.getenv("PRESENCE_TEST_SIGLIP2")));
        var image = ImageIO.read(Path.of(System.getenv("PRESENCE_TEST_PET")).toFile());
        var side = Math.max(image.getWidth(), image.getHeight());
        var square = new java.awt.image.BufferedImage(Embedder.SIZE, Embedder.SIZE,
                java.awt.image.BufferedImage.TYPE_INT_RGB);
        var g = square.createGraphics();
        g.setRenderingHint(java.awt.RenderingHints.KEY_INTERPOLATION,
                java.awt.RenderingHints.VALUE_INTERPOLATION_BILINEAR);
        var w = image.getWidth() * Embedder.SIZE / side;
        var h = image.getHeight() * Embedder.SIZE / side;
        g.drawImage(image, (Embedder.SIZE - w) / 2, (Embedder.SIZE - h) / 2, w, h, null);
        g.dispose();
        var pixels = new byte[Embedder.PIXELS];
        for (var y = 0; y < Embedder.SIZE; y++) {
            for (var x = 0; x < Embedder.SIZE; x++) {
                var rgb = square.getRGB(x, y);
                var i = (y * Embedder.SIZE + x) * 3;
                pixels[i] = (byte) (rgb >> 16);
                pixels[i + 1] = (byte) (rgb >> 8);
                pixels[i + 2] = (byte) rgb;
            }
        }
        var vector = model.embed(List.of(pixels))[0];
        assertEquals(PetLabels.DIMENSIONS, vector.length);
        var found = PetLabels.describe(vector, "cat");
        System.out.println("presence: " + found);
        assertTrue(found.stream().anyMatch(f -> f.label().equals("black cat")), found.toString());
    }
}
