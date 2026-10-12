package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import java.util.function.Supplier;

import static presence.auth.RecognitionApi.json;

/**
 * Cloud recognition's pet labels (premium only): {@code POST
 * /api/recognition/describe} {@code {"crops": [{id, kind, pixels}]}} (the
 * cats and dogs a new clip shows, up to {@link RecognitionApi#MAX_CROPS};
 * {@code kind}: {@code cat} or {@code dog}) answers each one's breed and
 * coat, those sure enough ({@link PetLabels}): {@code {"model", "results":
 * [{id, labels: [{label, type, confidence}]}]}}. It needs no training and
 * keeps nothing; it's its own function, so it never waits for
 * {@link InferenceHandler}'s model, nor it for this one. The app adds the
 * labels to the clip's object tags.
 */
public class DescribeHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    static final String MODEL = "siglip2-base-patch16-224";

    private final Function<Caller, RecognitionApi.Access> access;
    private final Supplier<Embedder> embedder;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public DescribeHandler() {
        this(RecognitionApi.accessFromEnvironment(), Siglip2::shared);
    }

    DescribeHandler(Function<Caller, RecognitionApi.Access> access, Supplier<Embedder> embedder) {
        this.access = access;
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
            if (!"POST /api/recognition/describe".equals(route)) {
                return Http.response(404, "{\"error\":\"no such route\"}");
            }
            return describe(RecognitionApi.body(event));
        } catch (RuntimeException e) {
            return Aws.failed("recognition", route, e, context);
        }
    }

    private APIGatewayV2HTTPResponse describe(Map<String, Object> body) {
        var crops = RecognitionApi.objects(body, "crops");
        if (crops == null || crops.isEmpty() || crops.size() > RecognitionApi.MAX_CROPS) {
            return Http.response(400, "{\"error\":\"crops: 1 to " + RecognitionApi.MAX_CROPS
                    + " of {id, kind, pixels}\"}");
        }
        var pixels = new ArrayList<byte[]>();
        for (var crop : crops) {
            var p = RecognitionApi.pixels(crop);
            if (RecognitionApi.text(crop, "id", RecognitionApi.MAX_ID) == null
                    || PetLabels.species(crop.get("kind")) == null || p == null) {
                return Http.response(400, "{\"error\":\"a crop needs an id, a kind (cat or dog)"
                        + " and pixels (224 x 224 RGB, base64)\"}");
            }
            pixels.add(p);
        }
        var vectors = embedder.get().embed(pixels);
        var results = new ArrayList<Map<String, Object>>();
        for (var i = 0; i < crops.size(); i++) {
            var labels = PetLabels.describe(vectors[i], PetLabels.species(crops.get(i).get("kind"))).stream()
                    .map(f -> Map.<String, Object>of("label", f.label(), "type", f.type(),
                            "confidence", f.confidence()))
                    .toList();
            results.add(Map.of("id", crops.get(i).get("id"), "labels", labels));
        }
        var out = new LinkedHashMap<String, Object>();
        out.put("model", MODEL);
        out.put("results", List.copyOf(results));
        return json(200, out);
    }
}
