package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.Supplier;

import static presence.auth.RecognitionApi.json;

/**
 * Cloud recognition's inference (premium only): {@code POST
 * /api/recognition/identify} {@code {"crops": [{id, kind, pixels}]}} (the
 * people and pets a new clip shows, up to {@link RecognitionApi#MAX_CROPS})
 * answers which of the profile's subjects each may be: {@code {"trainedAt",
 * "results": [{id, labels: [{name, confidence}]}]}}, each crop's
 * {@link #MAX_LABELS} likeliest subjects of its sort, surest first, from
 * {@link #MIN_CONFIDENCE}. The app places the labels: it tags the sure ones
 * and asks about the others, as it does with its own recognition. Without a
 * trained model it answers {@code trainedAt} null and no results, without
 * loading DINOv2.
 */
public class InferenceHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    static final int MAX_LABELS = 3;
    static final double MIN_CONFIDENCE = 0.05;

    private final Function<Caller, RecognitionApi.Access> access;
    private final RecognitionStore store;
    private final Supplier<Embedder> embedder;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public InferenceHandler() {
        this(RecognitionApi.accessFromEnvironment(),
                RecognitionStore.dynamo(Aws.dynamo(), System.getenv("RECOGNITION_TABLE")), Dinov2::shared);
    }

    InferenceHandler(Function<Caller, RecognitionApi.Access> access, RecognitionStore store,
                     Supplier<Embedder> embedder) {
        this.access = access;
        this.store = store;
        this.embedder = embedder;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var caller = Caller.from(event);
        var route = Http.route(event);
        try {
            var who = caller.hasSubject() ? access.apply(caller) : new RecognitionApi.Access(null, false);
            var refusal = RecognitionApi.refusal(caller, who);
            if (refusal != null) {
                return refusal;
            }
            if (!"POST /api/recognition/identify".equals(route)) {
                return Http.response(404, "{\"error\":\"no such route\"}");
            }
            return identify(who.profileId(), RecognitionApi.body(event));
        } catch (RuntimeException e) {
            return Aws.failed("recognition", route, e, context);
        }
    }

    private APIGatewayV2HTTPResponse identify(String profile, Map<String, Object> body) {
        var crops = RecognitionApi.objects(body, "crops");
        if (crops == null || crops.isEmpty() || crops.size() > RecognitionApi.MAX_CROPS) {
            return Http.response(400, "{\"error\":\"crops: 1 to " + RecognitionApi.MAX_CROPS
                    + " of {id, kind, pixels}\"}");
        }
        var pixels = new ArrayList<byte[]>();
        for (var crop : crops) {
            var p = RecognitionApi.pixels(crop);
            if (RecognitionApi.text(crop, "id", RecognitionApi.MAX_ID) == null
                    || Classifier.kind(crop.get("kind")) == null || p == null) {
                return Http.response(400, "{\"error\":\"a crop needs an id, a kind (person or pet)"
                        + " and pixels (224 x 224 RGB, base64)\"}");
            }
            pixels.add(p);
        }
        var model = store.model(profile);
        var out = new LinkedHashMap<String, Object>();
        if (model == null || model.subjects().isEmpty()) {
            out.put("trainedAt", model == null ? null : model.trainedAt());
            out.put("results", List.of());
            return json(200, out);
        }
        var vectors = embedder.get().embed(pixels);
        var results = new ArrayList<Map<String, Object>>();
        for (var i = 0; i < crops.size(); i++) {
            var kind = Classifier.kind(crops.get(i).get("kind"));
            var vector = vectors[i];
            var labels = model.subjects().stream()
                    .filter(s -> s.kind().equals(kind))
                    .map(s -> Map.<String, Object>of("name", s.name(), "confidence", s.probability(vector)))
                    .filter(m -> (double) m.get("confidence") >= MIN_CONFIDENCE)
                    .sorted(Comparator.comparingDouble(m -> -(double) m.get("confidence")))
                    .limit(MAX_LABELS)
                    .toList();
            results.add(Map.of("id", crops.get(i).get("id"), "labels", labels));
        }
        out.put("trainedAt", model.trainedAt());
        out.put("results", results);
        return json(200, out);
    }
}
