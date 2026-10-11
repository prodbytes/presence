package presence.auth;

import java.util.List;

/** Turns crops into unit-length embeddings: {@link Dinov2} in Lambda, fakes in tests. */
interface Embedder {

    /** A crop's side, in pixels. */
    int SIZE = 224;

    /** A crop's bytes: {@link #SIZE} × {@link #SIZE} pixels, RGB, row by row. */
    int PIXELS = SIZE * SIZE * 3;

    /** An embedding's length. */
    int DIMENSIONS = 1024;

    /** One unit-length embedding per crop ({@link #PIXELS} bytes each), in order. */
    float[][] embed(List<byte[]> crops);
}
