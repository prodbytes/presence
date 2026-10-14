package presence.auth;

import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import com.fasterxml.jackson.jr.ob.JSON;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RecognitionTest {

    /** The recognition table, in memory. */
    static final class MemoryStore implements RecognitionStore {
        final Map<String, Map<String, Classifier.Label>> labels = new HashMap<>();
        final Map<String, Model> models = new HashMap<>();

        @Override
        public List<Classifier.Label> labels(String profile) {
            return new ArrayList<>(labels.getOrDefault(profile, Map.of()).values());
        }

        @Override
        public void putLabel(String profile, Classifier.Label label) {
            labels.computeIfAbsent(profile, k -> new LinkedHashMap<>()).put(label.id(), label);
        }

        @Override
        public void deleteLabel(String profile, String id) {
            labels.getOrDefault(profile, new HashMap<>()).remove(id);
        }

        @Override
        public Model model(String profile) {
            return models.get(profile);
        }

        @Override
        public void putModel(String profile, Model model) {
            models.put(profile, model);
        }
    }

    /**
     * Each crop's color (its first pixel's red) picks a direction, plus a
     * little noise from the rest: crops of one color are one subject.
     */
    static final class FakeEmbedder implements Embedder {
        final AtomicInteger crops = new AtomicInteger();

        @Override
        public float[][] embed(List<byte[]> pixels) {
            var out = new float[pixels.size()][];
            for (var i = 0; i < pixels.size(); i++) {
                crops.incrementAndGet();
                var p = pixels.get(i);
                var v = new float[DIMENSIONS];
                var random = new Random((p[1] & 0xff) * 31L + (p[2] & 0xff));
                for (var j = 0; j < v.length; j++) {
                    v[j] = (float) random.nextGaussian() * 0.02f;
                }
                v[(p[0] & 0xff) % DIMENSIONS] += 1;
                Vectors.normalize(v);
                out[i] = v;
            }
            return out;
        }
    }

    static String crop(int color, int seed) {
        var p = new byte[Embedder.PIXELS];
        p[0] = (byte) color;
        p[1] = (byte) seed;
        p[2] = (byte) (seed >> 8);
        return Base64.getEncoder().encodeToString(p);
    }

    static APIGatewayV2HTTPEvent request(String route, Object body, boolean verified) throws IOException {
        var event = new APIGatewayV2HTTPEvent();
        event.setRouteKey(route);
        event.setBody(body == null ? null : JSON.std.asString(body));
        var claims = Map.of("idp", "https://accounts.google.com", "idp_sub", "123",
                "email", "julio@example.com", "email_verified", Boolean.toString(verified));
        var jwt = APIGatewayV2HTTPEvent.RequestContext.Authorizer.JWT.builder().withClaims(claims).build();
        var authorizer = APIGatewayV2HTTPEvent.RequestContext.Authorizer.builder().withJwt(jwt).build();
        event.setRequestContext(APIGatewayV2HTTPEvent.RequestContext.builder().withAuthorizer(authorizer).build());
        return event;
    }

    static Map<String, Object> json(APIGatewayV2HTTPResponse response) throws IOException {
        return JSON.std.mapFrom(response.getBody());
    }

    final MemoryStore store = new MemoryStore();
    final FakeEmbedder embedder = new FakeEmbedder();
    boolean premium = true;
    long now = 1_000;
    final TrainingHandler training = new TrainingHandler(
            caller -> new RecognitionApi.Access("brave_quiet_otter", premium), store, () -> embedder, () -> now);
    final InferenceHandler inference = new InferenceHandler(
            caller -> new RecognitionApi.Access("brave_quiet_otter", premium), store, () -> embedder);

    Map<String, Object> label(String id, String name, String kind, int color, int seed) {
        return Map.of("id", id, "clipId", "clip-" + id, "name", name, "kind", kind, "labeledAt", 500,
                "pixels", crop(color, seed));
    }

    @Test
    void premiumOnly() throws IOException {
        premium = false;
        var answer = training.handleRequest(request("GET /api/recognition/status", null, true), null);
        assertEquals(403, answer.getStatusCode());
        answer = inference.handleRequest(request("POST /api/recognition/identify",
                Map.of("crops", List.of(Map.of("id", "a", "kind", "cat", "pixels", crop(1, 1)))), true), null);
        assertEquals(403, answer.getStatusCode());
        premium = true;
        answer = training.handleRequest(request("GET /api/recognition/status", null, false), null);
        assertEquals(403, answer.getStatusCode(), "an unverified email");
    }

    @Test
    void neverTrained() throws IOException {
        var status = json(training.handleRequest(request("GET /api/recognition/status", null, true), null));
        assertEquals("dinov2-large", status.get("model"));
        assertNull(status.get("trainedAt"));
        assertEquals(List.of(), status.get("labels"));
        var answer = json(inference.handleRequest(request("POST /api/recognition/identify",
                Map.of("crops", List.of(Map.of("id", "a", "kind", "cat", "pixels", crop(1, 1)))), true), null));
        assertNull(answer.get("trainedAt"));
        assertEquals(List.of(), answer.get("results"));
        assertEquals(0, embedder.crops.get(), "no model: nothing embedded");
    }

    @Test
    void badLabelsAreRefused() throws IOException {
        var tooMany = new ArrayList<Map<String, Object>>();
        for (var i = 0; i < 9; i++) {
            tooMany.add(label("l" + i, "Suerte", "cat", 7, i));
        }
        assertEquals(400, training.handleRequest(request("POST /api/recognition/labels",
                Map.of("labels", tooMany), true), null).getStatusCode());
        var noPixels = new HashMap<>(label("l1", "Suerte", "cat", 7, 1));
        noPixels.put("pixels", "AAAA");
        assertEquals(400, training.handleRequest(request("POST /api/recognition/labels",
                Map.of("labels", List.of(noPixels)), true), null).getStatusCode());
        assertEquals(400, training.handleRequest(request("POST /api/recognition/labels",
                Map.of("labels", List.of(label("l1", "Suerte", "bicycle", 7, 1))), true), null).getStatusCode());
        assertEquals(400, training.handleRequest(request("POST /api/recognition/labels", null, true), null)
                .getStatusCode());
    }

    @Test
    void trainsAndIdentifies() throws IOException {
        var labels = new ArrayList<Map<String, Object>>();
        for (var i = 0; i < 4; i++) {
            labels.add(label("s" + i, "Suerte", "cat", 7, i));
        }
        for (var i = 0; i < 4; i++) {
            labels.add(label("f" + i, "Fido", "dog", 9, 100 + i));
        }
        var stored = json(training.handleRequest(request("POST /api/recognition/labels",
                Map.of("labels", labels), true), null));
        assertEquals(8, stored.get("stored"));
        assertEquals(8, stored.get("labels"));
        var status = json(training.handleRequest(request("GET /api/recognition/status", null, true), null));
        assertEquals(8, ((List<?>) status.get("labels")).size());
        assertNull(status.get("trainedAt"), "stored, not trained yet");

        // Fido's last label removed, and Suerte's first renamed " suerte ".
        var current = new ArrayList<Map<String, Object>>();
        for (var i = 0; i < 4; i++) {
            current.add(Map.of("id", "s" + i, "name", i == 0 ? " suerte " : "Suerte"));
        }
        for (var i = 0; i < 3; i++) {
            current.add(Map.of("id", "f" + i, "name", "Fido"));
        }
        var clips = List.of("clip-s0", "clip-s1", "clip-s2", "clip-s3", "clip-f0", "clip-f1", "clip-f2", "clip-f3");
        now = 2_000;
        var trained = json(training.handleRequest(request("POST /api/recognition/train",
                Map.of("labels", current, "clips", clips), true), null));
        assertEquals(2_000, ((Number) trained.get("trainedAt")).longValue());
        assertEquals(7, trained.get("labels"));
        var subjects = (List<?>) trained.get("subjects");
        assertEquals(2, subjects.size(), "Suerte and suerte are one subject");
        assertEquals(3, store.labels("brave_quiet_otter").stream().filter(l -> l.name().equals("Fido")).count());
        assertEquals(1, store.labels("brave_quiet_otter").stream().filter(l -> l.name().equals("suerte")).count());

        var answer = json(inference.handleRequest(request("POST /api/recognition/identify", Map.of("crops", List.of(
                Map.of("id", "a", "kind", "cat", "pixels", crop(7, 999)),
                Map.of("id", "b", "kind", "cat", "pixels", crop(200, 998)),
                Map.of("id", "c", "kind", "person", "pixels", crop(7, 997)))), true), null));
        assertEquals(2_000, ((Number) answer.get("trainedAt")).longValue());
        var results = (List<?>) answer.get("results");
        assertEquals(3, results.size());
        var a = (Map<?, ?>) results.get(0);
        assertEquals("a", a.get("id"));
        var best = (Map<?, ?>) ((List<?>) a.get("labels")).get(0);
        assertTrue(List.of("Suerte", "suerte").contains(best.get("name")), "named as on a label: " + best);
        assertTrue(((Number) best.get("confidence")).doubleValue() > 0.9, "Suerte's color: " + best);
        var b = (List<?>) ((Map<?, ?>) results.get(1)).get("labels");
        for (var l : b) {
            assertTrue(((Number) ((Map<?, ?>) l).get("confidence")).doubleValue() < 0.5, "another cat: " + l);
        }
        assertEquals(List.of(), ((Map<?, ?>) results.get(2)).get("labels"), "no person is known");
    }

    @Test
    void keepsLabelsOnClipsTheDeviceDoesntHave() throws IOException {
        training.handleRequest(request("POST /api/recognition/labels", Map.of("labels", List.of(
                label("old", "Suerte", "cat", 7, 1), label("gone", "Suerte", "cat", 7, 2),
                label("here", "Suerte", "cat", 7, 3))), true), null);
        // This device has the clips of "gone" (removed there) and "here", not "old"'s.
        var trained = json(training.handleRequest(request("POST /api/recognition/train", Map.of(
                "labels", List.of(Map.of("id", "here", "name", "Suerte")),
                "clips", List.of("clip-gone", "clip-here")), true), null));
        assertEquals(2, trained.get("labels"));
        assertEquals(List.of("here", "old"), store.labels("brave_quiet_otter").stream()
                .map(Classifier.Label::id).sorted().toList());
    }

    @Test
    void negativesLoad() {
        assertEquals(400, Classifier.NEGATIVES.get(Classifier.PERSON).size());
        assertEquals(364, Classifier.NEGATIVES.get(Classifier.PET).size());
        var v = Classifier.NEGATIVES.get(Classifier.PET).get(0);
        assertEquals(1, Math.sqrt(Vectors.dot(v, v)), 0.01, "unit length");
    }

    @Test
    void vectorsRoundTrip() {
        var v = new float[]{1.5f, -2, 0.25f};
        assertEquals(List.of(1.5f, -2f, 0.25f), toList(Vectors.fromBytes(Vectors.toBytes(v), 3)));
        assertNull(Vectors.fromBytes(new byte[5], 3));
    }

    private static List<Float> toList(float[] v) {
        var out = new ArrayList<Float>();
        for (var x : v) {
            out.add(x);
        }
        return out;
    }
}
