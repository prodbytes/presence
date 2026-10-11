package presence.auth;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Embeddings' arithmetic and storage (float32, little-endian). */
final class Vectors {

    private Vectors() {
    }

    /** Makes {@code v} unit length in place (a zero vector stays zero). */
    static void normalize(float[] v) {
        double sum = 0;
        for (var x : v) {
            sum += (double) x * x;
        }
        if (sum == 0) {
            return;
        }
        var scale = (float) (1 / Math.sqrt(sum));
        for (var i = 0; i < v.length; i++) {
            v[i] *= scale;
        }
    }

    static double dot(float[] a, float[] b) {
        double sum = 0;
        for (var i = 0; i < a.length; i++) {
            sum += (double) a[i] * b[i];
        }
        return sum;
    }

    static byte[] toBytes(float[] v) {
        var buffer = ByteBuffer.allocate(v.length * 4).order(ByteOrder.LITTLE_ENDIAN);
        buffer.asFloatBuffer().put(v);
        return buffer.array();
    }

    /** Null if {@code bytes} isn't {@code length} floats. */
    static float[] fromBytes(byte[] bytes, int length) {
        if (bytes == null || bytes.length != length * 4) {
            return null;
        }
        var v = new float[length];
        ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(v);
        return v;
    }
}
