package presence.payments;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.Signature;
import java.security.cert.CertPathValidator;
import java.security.cert.CertificateFactory;
import java.security.cert.PKIXParameters;
import java.security.cert.TrustAnchor;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Date;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Verifies the App Store's signed data (JWS, compact form, ES256): StoreKit
 * 2's signed transactions ({@code jwsRepresentation}), their renewal info,
 * and App Store Server Notifications V2. Apple signs each with a leaf
 * certificate carried in the header's {@code x5c}, with the chain leaf,
 * intermediate, root:
 * <ul>
 *   <li>the root must be <b>Apple Root CA - G3</b>, byte for byte (its
 *       DER is below, checked against its published SHA-256 fingerprint);</li>
 *   <li>the chain must validate (PKIX) to that root at the payload's
 *       {@code signedDate}, as Apple's own libraries do offline;</li>
 *   <li>the intermediate must carry Apple's OID {@code
 *       1.2.840.113635.100.6.2.1} (Apple Worldwide Developer Relations
 *       intermediate) and the leaf {@code 1.2.840.113635.100.6.11.1}
 *       (App Store receipt signing);</li>
 *   <li>the leaf's key must verify the signature.</li>
 * </ul>
 * Online revocation checks (OCSP) aren't made.
 */
final class AppleJws {

    /** Apple Root CA - G3 (https://www.apple.com/certificateauthority/AppleRootCA-G3.cer), DER, base64. */
    static final String APPLE_ROOT_CA_G3 = """
            MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9v\
            dCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UE\
            CgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2\
            WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmlj\
            YXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqG\
            SM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxE\
            tX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNC\
            MEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P\
            AQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3m\
            eoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkL\
            F1vLUagM6BgD56KyKA==""";

    /** Apple Root CA - G3's published SHA-256 fingerprint. */
    static final String APPLE_ROOT_CA_G3_SHA256 =
            "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";

    /** Apple's OID on the WWDR intermediate. */
    static final String INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";

    /** Apple's OID on the App Store's signing leaf. */
    static final String LEAF_OID = "1.2.840.113635.100.6.11.1";

    /** The longest JWS taken (a signed transaction is about 4 KB; a notification's payload holds two). */
    static final int MAX_LENGTH = 64 * 1024;

    private final X509Certificate root;

    /** Trusts {@code root} only (Apple Root CA - G3 in production, a test root in tests). */
    AppleJws(X509Certificate root) {
        this.root = root;
    }

    /** Trusts Apple Root CA - G3. */
    static AppleJws apple() {
        var der = Base64.getDecoder().decode(APPLE_ROOT_CA_G3);
        try {
            var sha256 = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(der));
            if (!sha256.equals(APPLE_ROOT_CA_G3_SHA256)) {
                throw new IllegalStateException("the bundled Apple root isn't Apple Root CA - G3");
            }
            return new AppleJws(certificate(der));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("the bundled Apple root doesn't load", e);
        }
    }

    /** Why a JWS was refused. */
    static final class InvalidJws extends Exception {
        InvalidJws(String message) {
            super(message);
        }
    }

    /** The payload of {@code jws}, once its signature and chain check out. */
    Map<String, Object> verify(String jws) throws InvalidJws {
        if (jws == null || jws.isEmpty() || jws.length() > MAX_LENGTH) {
            throw new InvalidJws("no signed data, or too long");
        }
        var parts = jws.split("\\.", -1);
        if (parts.length != 3) {
            throw new InvalidJws("not a compact JWS");
        }
        Map<String, Object> header;
        Map<String, Object> payload;
        byte[] signature;
        try {
            header = JsonReader.object(new String(decode(parts[0]), StandardCharsets.UTF_8));
            payload = JsonReader.object(new String(decode(parts[1]), StandardCharsets.UTF_8));
            signature = decode(parts[2]);
        } catch (IllegalArgumentException e) {
            throw new InvalidJws("not a JWS: " + e.getMessage());
        }
        if (!"ES256".equals(JsonReader.string(header, "alg"))) {
            throw new InvalidJws("not ES256");
        }
        var x5c = JsonReader.list(header, "x5c");
        if (x5c.size() != 3) {
            throw new InvalidJws("x5c must be leaf, intermediate and root");
        }
        var chain = new ArrayList<X509Certificate>();
        try {
            for (var entry : x5c) {
                if (!(entry instanceof String b64)) {
                    throw new InvalidJws("x5c entries must be strings");
                }
                chain.add(certificate(Base64.getDecoder().decode(b64)));
            }
        } catch (IllegalArgumentException | GeneralSecurityException e) {
            throw new InvalidJws("x5c isn't certificates");
        }
        var leaf = chain.get(0);
        var intermediate = chain.get(1);
        try {
            if (!Arrays.equals(chain.get(2).getEncoded(), root.getEncoded())) {
                throw new InvalidJws("the chain's root isn't Apple Root CA - G3");
            }
        } catch (GeneralSecurityException e) {
            throw new InvalidJws("the chain's root doesn't encode");
        }
        if (intermediate.getExtensionValue(INTERMEDIATE_OID) == null) {
            throw new InvalidJws("the intermediate isn't Apple's WWDR");
        }
        if (leaf.getExtensionValue(LEAF_OID) == null) {
            throw new InvalidJws("the leaf isn't the App Store's");
        }
        var signedDate = JsonReader.number(payload, "signedDate");
        var at = signedDate == null ? Instant.now() : Instant.ofEpochMilli(signedDate);
        try {
            var factory = CertificateFactory.getInstance("X.509");
            var path = factory.generateCertPath(List.of(leaf, intermediate));
            var parameters = new PKIXParameters(Set.of(new TrustAnchor(root, null)));
            parameters.setRevocationEnabled(false);
            parameters.setDate(Date.from(at));
            CertPathValidator.getInstance("PKIX").validate(path, parameters);
        } catch (GeneralSecurityException e) {
            throw new InvalidJws("the chain doesn't validate: " + e.getMessage());
        }
        try {
            var verifier = Signature.getInstance("SHA256withECDSAinP1363Format");
            verifier.initVerify(leaf.getPublicKey());
            verifier.update((parts[0] + "." + parts[1]).getBytes(StandardCharsets.US_ASCII));
            if (!verifier.verify(signature)) {
                throw new InvalidJws("the signature doesn't match");
            }
        } catch (GeneralSecurityException e) {
            throw new InvalidJws("the signature doesn't verify");
        }
        return payload;
    }

    private static byte[] decode(String part) {
        return Base64.getUrlDecoder().decode(part);
    }

    private static X509Certificate certificate(byte[] der) throws GeneralSecurityException {
        return (X509Certificate) CertificateFactory.getInstance("X.509")
                .generateCertificate(new ByteArrayInputStream(der));
    }
}
