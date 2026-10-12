package presence.auth;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtException;
import ai.onnxruntime.OrtSession;

import java.nio.FloatBuffer;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * DINOv2 ViT-L/14 ({@code facebook/dinov2-large}, Apache-2.0) as ONNX
 * ({@code onnx-community/dinov2-large}, fp32), on the CPU with ONNX Runtime.
 * A crop is 224 px square, normalized with ImageNet's mean and deviation;
 * its embedding is the class token of the last layer (1024 values), made
 * unit length. In fp32 at 224 px it separated one black cat from 18 others
 * as well as PyTorch at 518 px; int8 was worse (specs/cloud-recognition.md).
 */
final class Dinov2 implements Embedder {

    private static final float[] MEAN = {0.485f, 0.456f, 0.406f};
    private static final float[] STD = {0.229f, 0.224f, 0.225f};

    /** Tokens per crop: the class token and 16 × 16 patches. */
    private static final int TOKENS = 1 + (SIZE / 14) * (SIZE / 14);

    private static Dinov2 shared;

    private final OrtEnvironment env;
    private final OrtSession session;

    Dinov2(Path model) {
        try {
            env = OrtEnvironment.getEnvironment();
            var options = new OrtSession.SessionOptions();
            options.setIntraOpNumThreads(Math.max(1, Runtime.getRuntime().availableProcessors()));
            options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT);
            session = env.createSession(model.toString(), options);
        } catch (OrtException e) {
            throw new IllegalStateException("DINOv2 didn't load", e);
        }
    }

    /** The function instance's model, fetched ({@link ModelFile}) and loaded at its first use. */
    static synchronized Dinov2 shared() {
        if (shared == null) {
            shared = new Dinov2(ModelFile.fromEnvironment(ModelFile.DINOV2).path());
        }
        return shared;
    }

    @Override
    public float[][] embed(List<byte[]> crops) {
        var n = crops.size();
        if (n == 0) {
            return new float[0][];
        }
        var input = FloatBuffer.allocate(n * 3 * SIZE * SIZE);
        for (var crop : crops) {
            if (crop.length != PIXELS) {
                throw new IllegalArgumentException("a crop is " + PIXELS + " bytes");
            }
            // HWC bytes to CHW floats.
            for (var c = 0; c < 3; c++) {
                for (var i = 0; i < SIZE * SIZE; i++) {
                    input.put(((crop[i * 3 + c] & 0xff) / 255f - MEAN[c]) / STD[c]);
                }
            }
        }
        input.rewind();
        try (var tensor = OnnxTensor.createTensor(env, input, new long[]{n, 3, SIZE, SIZE});
             var result = session.run(Map.of("pixel_values", tensor))) {
            var hidden = ((OnnxTensor) result.get(0)).getFloatBuffer();
            var out = new float[n][DIMENSIONS];
            for (var b = 0; b < n; b++) {
                hidden.get(b * TOKENS * DIMENSIONS, out[b]);
                Vectors.normalize(out[b]);
            }
            return out;
        } catch (OrtException e) {
            throw new IllegalStateException("DINOv2 failed", e);
        }
    }
}
