package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.LongSupplier;
import java.util.function.Supplier;

import static presence.auth.RecognitionApi.json;

/**
 * Cloud recognition's training (premium only): the app sends the labels
 * people placed (a crop of each), and asks for a training when enough are
 * new or enough time has passed (it decides; see specs/cloud-recognition.md).
 * <ul>
 *   <li>{@code GET /api/recognition/status}: {@code {"model", "trainedAt"
 *       (null if never), "labels": [{id, labeledAt}], "subjects": [{name,
 *       kind, labels}]}};</li>
 *   <li>{@code POST /api/recognition/labels} {@code {"labels": [{id, clipId,
 *       name, kind, labeledAt, pixels}]}} (up to {@link RecognitionApi#MAX_CROPS};
 *       {@code pixels}: a 224 × 224 RGB crop in base64): each crop's
 *       embedding is kept (the crop isn't), as {@code {"stored", "labels"}};</li>
 *   <li>{@code POST /api/recognition/train} {@code {"labels": [{id, name}],
 *       "clips": [id]}}: the labels on the clips the device has ({@code
 *       clips}). Labels kept on those clips but not among them were
 *       removed, and are forgotten; those on other clips (beyond the
 *       device's history) stay; renamed ones are renamed. Then every subject
 *       is learned again ({@link Classifier}): {@code {"trainedAt",
 *       "labels", "subjects"}}.</li>
 * </ul>
 */
public class TrainingHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** Which model the labels' embeddings come from. */
    static final String MODEL = "dinov2-large";

    /** The most labels a profile keeps. */
    static final int MAX_LABELS = 2000;

    private final Function<Caller, RecognitionApi.Access> access;
    private final RecognitionStore store;
    private final Supplier<Embedder> embedder;
    private final LongSupplier now;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public TrainingHandler() {
        this(RecognitionApi.accessFromEnvironment(),
                RecognitionStore.dynamo(Aws.dynamo(), System.getenv("RECOGNITION_TABLE")),
                Dinov2::shared, System::currentTimeMillis);
    }

    TrainingHandler(Function<Caller, RecognitionApi.Access> access, RecognitionStore store,
                    Supplier<Embedder> embedder, LongSupplier now) {
        this.access = access;
        this.store = store;
        this.embedder = embedder;
        this.now = now;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        // Only through the site (CloudFront), never the API's own host.
        if (!OriginCheck.fromEnvironment().allows(event)) {
            return OriginCheck.refused();
        }
        var caller = Caller.from(event);
        var route = Http.route(event);
        try {
            var who = caller.hasSubject() ? access.apply(caller) : new RecognitionApi.Access(null, false);
            var refusal = RecognitionApi.refusal(caller, who);
            if (refusal != null) {
                return refusal;
            }
            return switch (route) {
                case "GET /api/recognition/status" -> status(who.profileId());
                case "POST /api/recognition/labels" -> labels(who.profileId(), RecognitionApi.body(event));
                case "POST /api/recognition/train" -> train(who.profileId(), RecognitionApi.body(event));
                default -> Http.response(404, "{\"error\":\"no such route\"}");
            };
        } catch (RuntimeException e) {
            return Aws.failed("recognition", route, e, context);
        }
    }

    private APIGatewayV2HTTPResponse status(String profile) {
        var model = store.model(profile);
        var labels = new ArrayList<Map<String, Object>>();
        for (var label : store.labels(profile)) {
            labels.add(Map.of("id", label.id(), "labeledAt", label.labeledAt()));
        }
        var out = new LinkedHashMap<String, Object>();
        out.put("model", MODEL);
        out.put("trainedAt", model == null ? null : model.trainedAt());
        out.put("labels", labels);
        out.put("subjects", model == null ? List.of() : subjects(model));
        return json(200, out);
    }

    private APIGatewayV2HTTPResponse labels(String profile, Map<String, Object> body) {
        var entries = RecognitionApi.objects(body, "labels");
        if (entries == null || entries.isEmpty() || entries.size() > RecognitionApi.MAX_CROPS) {
            return Http.response(400, "{\"error\":\"labels: 1 to " + RecognitionApi.MAX_CROPS
                    + " of {id, name, kind, labeledAt, pixels}\"}");
        }
        var crops = new ArrayList<byte[]>();
        for (var entry : entries) {
            var pixels = RecognitionApi.pixels(entry);
            if (RecognitionApi.text(entry, "id", RecognitionApi.MAX_ID) == null
                    || RecognitionApi.text(entry, "name", RecognitionApi.MAX_NAME) == null
                    || Classifier.kind(entry.get("kind")) == null
                    || !(entry.get("labeledAt") instanceof Number) || pixels == null) {
                return Http.response(400, "{\"error\":\"a label needs an id, a name, a kind (person or pet),"
                        + " labeledAt (ms) and pixels (224 x 224 RGB, base64)\"}");
            }
            crops.add(pixels);
        }
        var stored = store.labels(profile);
        var known = new HashMap<String, Classifier.Label>();
        stored.forEach(l -> known.put(l.id(), l));
        var added = entries.stream().filter(e -> !known.containsKey((String) e.get("id"))).count();
        if (stored.size() + added > MAX_LABELS) {
            return Http.response(413, "{\"error\":\"a profile keeps at most " + MAX_LABELS + " labels\"}");
        }
        var model0 = System.nanoTime();
        var dinov2 = embedder.get();
        var modelMs = Timing.since(model0);
        var embed0 = System.nanoTime();
        var vectors = dinov2.embed(crops);
        Timing.request("labels", crops.size(), modelMs, Timing.since(embed0), Timing.since(model0));
        for (var i = 0; i < entries.size(); i++) {
            var entry = entries.get(i);
            store.putLabel(profile, new Classifier.Label((String) entry.get("id"),
                    RecognitionApi.text(entry, "clipId", RecognitionApi.MAX_ID),
                    ((String) entry.get("name")).strip(), Classifier.kind(entry.get("kind")),
                    ((Number) entry.get("labeledAt")).longValue(), vectors[i]));
        }
        return json(200, Map.of("stored", entries.size(), "labels", stored.size() + (int) added));
    }

    private APIGatewayV2HTTPResponse train(String profile, Map<String, Object> body) {
        var entries = RecognitionApi.objects(body, "labels");
        if (entries == null || entries.size() > MAX_LABELS) {
            return Http.response(400, "{\"error\":\"labels: the profile's labels now, [{id, name}]\"}");
        }
        var clips = new HashSet<String>();
        if (body.get("clips") instanceof List<?> list) {
            for (var clip : list) {
                if (clip instanceof String id) {
                    clips.add(id);
                }
            }
        }
        var current = new HashMap<String, String>();
        for (var entry : entries) {
            var id = RecognitionApi.text(entry, "id", RecognitionApi.MAX_ID);
            var name = RecognitionApi.text(entry, "name", RecognitionApi.MAX_NAME);
            if (id == null || name == null) {
                return Http.response(400, "{\"error\":\"a label needs an id and a name\"}");
            }
            current.put(id, name.strip());
        }
        var kept = new ArrayList<Classifier.Label>();
        for (var label : store.labels(profile)) {
            var name = current.get(label.id());
            if (name == null && label.clipId() != null && !clips.contains(label.clipId())) {
                // On a clip the device doesn't have: kept as it is.
                kept.add(label);
            } else if (name == null) {
                // Removed from its clip: forgotten.
                store.deleteLabel(profile, label.id());
            } else if (!name.equals(label.name())) {
                var renamed = new Classifier.Label(label.id(), label.clipId(), name, label.kind(), label.labeledAt(),
                        label.vector());
                store.putLabel(profile, renamed);
                kept.add(renamed);
            } else {
                kept.add(label);
            }
        }
        var model = new RecognitionStore.Model(now.getAsLong(), kept.size(), Classifier.train(kept));
        store.putModel(profile, model);
        var out = new LinkedHashMap<String, Object>();
        out.put("trainedAt", model.trainedAt());
        out.put("labels", model.labels());
        out.put("subjects", subjects(model));
        return json(200, out);
    }

    private static List<Map<String, Object>> subjects(RecognitionStore.Model model) {
        return model.subjects().stream()
                .map(s -> Map.<String, Object>of("name", s.name(), "kind", s.kind(), "labels", s.labels()))
                .toList();
    }
}
