package presence.auth;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtException;
import ai.onnxruntime.OrtSession;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * SigLIP2's image tower ({@code google/siglip2-base-patch16-224},
 * Apache-2.0) as ONNX ({@code onnx-community/siglip2-base-patch16-224-ONNX},
 * int8), on the CPU with ONNX Runtime: a crop (224 px square, scaled to -1
 * to 1) to its pooled embedding ({@link PetLabels#DIMENSIONS} values), made
 * unit length, in the space of the text embeddings of {@link PetLabels}. In
 * int8 it named the Oxford-IIIT pets' breeds as well as in fp32, at a
 * quarter of the size (specs/cloud-recognition.md).
 */
final class Siglip2 implements Embedder {

    private static Siglip2 shared;

    private final OrtEnvironment env;
    private final OrtSession session;

    Siglip2(Path model) {
        var started = System.nanoTime();
        try {
            env = OrtEnvironment.getEnvironment();
            var options = new OrtSession.SessionOptions();
            options.setIntraOpNumThreads(Timing.threads());
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
            session = env.createSession(model.toString(), options);
        } catch (OrtException e) {
            throw new IllegalStateException("SigLIP2 didn't load", e);
        }
        Timing.log("load siglip2-base-vision-int8", Timing.since(started), "");
    }

    /** The function instance's model, fetched ({@link ModelFile}) and loaded at its first use. */
    static synchronized Siglip2 shared() {
        if (shared == null) {
            shared = new Siglip2(ModelFile.fromEnvironment(ModelFile.SIGLIP2).path());
        }
        return shared;
    }

    @Override
    public float[][] embed(List<byte[]> crops) {
        var n = crops.size();
        if (n == 0) {
            return new float[0][];
        }
        // Direct, in native order: ONNX Runtime reads it in place, no copy.
        var input = ByteBuffer.allocateDirect(n * 3 * SIZE * SIZE * Float.BYTES)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();
        for (var crop : crops) {
            if (crop.length != PIXELS) {
                throw new IllegalArgumentException("a crop is " + PIXELS + " bytes");
            }
            // HWC bytes to CHW floats, from -1 to 1.
            for (var c = 0; c < 3; c++) {
                for (var i = 0; i < SIZE * SIZE; i++) {
                    input.put((crop[i * 3 + c] & 0xff) / 127.5f - 1);
                }
            }
        }
        input.rewind();
        try (var tensor = OnnxTensor.createTensor(env, input, new long[]{n, 3, SIZE, SIZE});
             var result = session.run(Map.of("pixel_values", tensor), Set.of("pooler_output"))) {
            var pooled = ((OnnxTensor) result.get(0)).getFloatBuffer();
            var out = new float[n][PetLabels.DIMENSIONS];
            for (var b = 0; b < n; b++) {
                pooled.get(out[b]);
                Vectors.normalize(out[b]);
            }
            return out;
        } catch (OrtException e) {
            throw new IllegalStateException("SigLIP2 failed", e);
        }
    }
}
