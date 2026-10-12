package presence.auth;

import software.amazon.awssdk.core.sync.RequestBody;
import software.amazon.awssdk.services.s3.S3Client;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.HexFormat;

/**
 * A model's file (DINOv2's is 1.2 GB, SigLIP2's 95 MB): too big for a
 * Lambda package, so a function fetches it at its first use, into
 * {@code /tmp} (the function's ephemeral storage). From the user-data bucket's {@code models/} prefix,
 * which only the functions reach (people's folders are their identity's),
 * or else from Hugging Face at a pinned revision, then kept in the bucket
 * for the next. Either way its SHA-256 must be {@link #sha256}, or it isn't
 * used.
 */
final class ModelFile {

    /** {@link Dinov2}'s: {@code onnx-community/dinov2-large}, fp32. */
    static final Source DINOV2 = new Source("dinov2-large",
            "https://huggingface.co/onnx-community/dinov2-large/resolve/"
                    + "4b3550c593d51ac1a870d48d411f35eff4eaf353/onnx/model.onnx",
            "305351060a1939d944e2dbe97dd64e4937ce5a220dce254e4cd74c7e4777d6ac");

    /** {@link Siglip2}'s: {@code onnx-community/siglip2-base-patch16-224-ONNX}'s vision tower, int8. */
    static final Source SIGLIP2 = new Source("siglip2-base-vision-int8",
            "https://huggingface.co/onnx-community/siglip2-base-patch16-224-ONNX/resolve/"
                    + "ba1f3b0843f24bc5417d38e19c37b287d719b2f4/onnx/vision_model_int8.onnx",
            "0dd31785a2713f1113ef2272472165c69d580473dae38d7b47568ac587795e70");

    /** Where a model comes from: its name (in file names), its pinned URL and its SHA-256. */
    record Source(String name, String url, String sha256) {
    }

    private final String name;
    private final String url;
    private final String sha256;
    private final String bucket;
    private final Path dir;

    /**
     * @param bucket the user-data bucket, or null/blank: Hugging Face only,
     *               nothing kept (local, Floci)
     */
    ModelFile(Source source, String bucket, Path dir) {
        this.name = source.name();
        this.url = source.url();
        this.sha256 = source.sha256();
        this.bucket = bucket == null || bucket.isBlank() ? null : bucket;
        this.dir = dir;
    }

    /** {@code source}'s file: kept in {@code MODEL_BUCKET} (the user-data bucket), fetched into {@code /tmp}. */
    static ModelFile fromEnvironment(Source source) {
        return new ModelFile(source, System.getenv("MODEL_BUCKET"), Path.of("/tmp"));
    }

    /** Where it's kept in the bucket. */
    String key() {
        return "models/" + name + "-" + sha256.substring(0, 16) + ".onnx";
    }

    /** The model's file, fetched if this instance hasn't yet. */
    Path path() {
        var file = dir.resolve(name + "-" + sha256.substring(0, 16) + ".onnx");
        if (Files.isRegularFile(file)) {
            return file;
        }
        var partial = dir.resolve(file.getFileName() + ".part");
        if (bucket != null) {
            try (var s3 = s3()) {
                try (var in = s3.getObject(b -> b.bucket(bucket).key(key()))) {
                    if (save(in, partial)) {
                        Files.move(partial, file, StandardCopyOption.REPLACE_EXISTING);
                        return file;
                    }
                    System.err.println("presence: the model in the bucket isn't the right one; fetching it again");
                } catch (RuntimeException | IOException e) {
                    System.err.println("presence: no model in the bucket (" + e.getClass().getSimpleName()
                            + "); fetching it from Hugging Face");
                }
            }
        }
        download(partial);
        try {
            Files.move(partial, file, StandardCopyOption.REPLACE_EXISTING);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        if (bucket != null) {
            try (var s3 = s3()) {
                s3.putObject(b -> b.bucket(bucket).key(key()), RequestBody.fromFile(file));
            } catch (RuntimeException e) {
                // The next instance fetches it from Hugging Face again.
                System.err.println("presence: couldn't keep the model in the bucket: " + Aws.cause(e));
            }
        }
        return file;
    }

    private void download(Path partial) {
        var client = HttpClient.newBuilder()
                .followRedirects(HttpClient.Redirect.NORMAL)
                .connectTimeout(Duration.ofSeconds(10))
                .build();
        try {
            var response = client.send(HttpRequest.newBuilder(URI.create(url)).GET().build(),
                    HttpResponse.BodyHandlers.ofInputStream());
            try (var in = response.body()) {
                if (response.statusCode() != 200) {
                    throw new IllegalStateException("the model's download answered " + response.statusCode());
                }
                if (!save(in, partial)) {
                    throw new IllegalStateException("the downloaded model's SHA-256 isn't " + sha256);
                }
            }
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(e);
        }
    }

    /** Copies {@code in} to {@code to}; whether its SHA-256 is {@link #sha256} (if not, it's deleted). */
    boolean save(InputStream in, Path to) throws IOException {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
        try (var hashed = new DigestInputStream(in, digest)) {
            Files.copy(hashed, to, StandardCopyOption.REPLACE_EXISTING);
        }
        if (HexFormat.of().formatHex(digest.digest()).equals(sha256)) {
            return true;
        }
        Files.deleteIfExists(to);
        return false;
    }

    private static S3Client s3() {
        return S3Client.builder().httpClient(Aws.http()).build();
    }
}
