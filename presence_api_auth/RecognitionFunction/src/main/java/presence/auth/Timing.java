package presence.auth;

/**
 * Logs how long recognition's steps take, one line each in the function's
 * log (CloudWatch): {@code presence: timing <step> <ms> ms ...}, with the
 * function's memory and the threads ONNX Runtime uses, so runs at different
 * memory sizes compare (specs/cloud-recognition.md, "Timing").
 */
final class Timing {

    private Timing() {
    }

    /** Milliseconds since {@code startNanos} ({@link System#nanoTime()}). */
    static long since(long startNanos) {
        return (System.nanoTime() - startNanos) / 1_000_000;
    }

    /** The CPU threads a model runs on: as many as the function has. */
    static int threads() {
        return Math.max(1, Runtime.getRuntime().availableProcessors());
    }

    /** Logs {@code step} taking {@code ms}, with {@code details} ("crops=8"). */
    static void log(String step, long ms, String details) {
        System.out.println("presence: timing " + step + " " + ms + " ms " + details
                + " threads=" + threads() + " memory=" + System.getenv("AWS_LAMBDA_FUNCTION_MEMORY_SIZE") + "MB");
    }

    /**
     * A request's embedding: the model's wait ({@code modelMs}: its fetch
     * and load on a new instance, about 0 after) and the embedding itself.
     */
    static void request(String route, int crops, long modelMs, long embedMs, long totalMs) {
        log(route, totalMs, "crops=" + crops + " model=" + modelMs + "ms embed=" + embedMs + "ms");
    }
}
