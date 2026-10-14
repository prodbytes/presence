package presence.auth;

import software.amazon.awssdk.core.SdkBytes;
import software.amazon.awssdk.services.kms.KmsClient;
import software.amazon.awssdk.services.kms.model.GetPublicKeyRequest;
import software.amazon.awssdk.services.kms.model.MessageType;
import software.amazon.awssdk.services.kms.model.SignRequest;
import software.amazon.awssdk.services.kms.model.SigningAlgorithmSpec;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.MessageDigest;
import java.security.interfaces.RSAPublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Signs Presence session tokens (RS256) and names the key that verifies
 * them. In AWS, {@link Kms}: the auth stack's KMS key (RSA_2048,
 * SIGN_VERIFY), whose private half never leaves KMS; the function may only
 * {@code kms:Sign} with it and read its public key.
 */
interface SessionSigner {

    /** The public key that verifies what this signs. */
    RSAPublicKey publicKey();

    /** RSASSA-PKCS1-v1_5 with SHA-256 over {@code input}: a JWS RS256 signature. */
    byte[] sign(byte[] input);

    /** The key's ID ({@code kid}): its RFC 7638 JWK thumbprint, so it changes only with the key. */
    default String kid() {
        return thumbprint(publicKey());
    }

    /** The public key as a JWK, for {@code /.well-known/jwks.json}. */
    default Map<String, Object> jwk() {
        var jwk = new LinkedHashMap<String, Object>();
        jwk.put("kty", "RSA");
        jwk.put("kid", kid());
        jwk.put("use", "sig");
        jwk.put("alg", "RS256");
        jwk.put("n", Jwt.base64(unsigned(publicKey().getModulus().toByteArray())));
        jwk.put("e", Jwt.base64(unsigned(publicKey().getPublicExponent().toByteArray())));
        return jwk;
    }

    /** RFC 7638: SHA-256 of {@code {"e","kty","n"}} in that order, base64url. */
    static String thumbprint(RSAPublicKey key) {
        var json = "{\"e\":\"" + Jwt.base64(unsigned(key.getPublicExponent().toByteArray()))
                + "\",\"kty\":\"RSA\",\"n\":\"" + Jwt.base64(unsigned(key.getModulus().toByteArray())) + "\"}";
        try {
            return Jwt.base64(MessageDigest.getInstance("SHA-256").digest(json.getBytes(StandardCharsets.UTF_8)));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    /** A big-endian integer without its sign byte, as JWKs carry them. */
    private static byte[] unsigned(byte[] bytes) {
        if (bytes.length > 1 && bytes[0] == 0) {
            var trimmed = new byte[bytes.length - 1];
            System.arraycopy(bytes, 1, trimmed, 0, trimmed.length);
            return trimmed;
        }
        return bytes;
    }

    /** The auth stack's KMS key ({@code SIGNING_KEY_ARN}). */
    final class Kms implements SessionSigner {

        private final KmsClient kms;
        private final String keyId;
        private volatile RSAPublicKey publicKey;
        private volatile String kid;

        Kms(KmsClient kms, String keyId) {
            this.kms = kms;
            this.keyId = keyId;
        }

        @Override
        public RSAPublicKey publicKey() {
            var key = publicKey;
            if (key == null) {
                // Once per function instance: the key never changes.
                var der = kms.getPublicKey(GetPublicKeyRequest.builder().keyId(keyId).build()).publicKey();
                try {
                    key = (RSAPublicKey) KeyFactory.getInstance("RSA")
                            .generatePublic(new X509EncodedKeySpec(der.asByteArray()));
                } catch (GeneralSecurityException e) {
                    throw new IllegalStateException("the signing key isn't an RSA key", e);
                }
                publicKey = key;
            }
            return key;
        }

        @Override
        public String kid() {
            var id = kid;
            if (id == null) {
                kid = id = SessionSigner.thumbprint(publicKey());
            }
            return id;
        }

        @Override
        public byte[] sign(byte[] input) {
            byte[] digest;
            try {
                digest = MessageDigest.getInstance("SHA-256").digest(input);
            } catch (GeneralSecurityException e) {
                throw new IllegalStateException(e);
            }
            return kms.sign(SignRequest.builder()
                    .keyId(keyId)
                    .message(SdkBytes.fromByteArray(digest))
                    .messageType(MessageType.DIGEST)
                    .signingAlgorithm(SigningAlgorithmSpec.RSASSA_PKCS1_V1_5_SHA_256)
                    .build()).signature().asByteArray();
        }
    }
}
