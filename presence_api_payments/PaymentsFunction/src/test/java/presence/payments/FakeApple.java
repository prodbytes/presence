package presence.payments;

import org.bouncycastle.asn1.ASN1ObjectIdentifier;
import org.bouncycastle.asn1.DERNull;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.asn1.x509.BasicConstraints;
import org.bouncycastle.asn1.x509.Extension;
import org.bouncycastle.asn1.x509.KeyUsage;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Date;
import java.util.concurrent.atomic.AtomicLong;

/**
 * A stand-in for Apple's App Store signing: a root, an intermediate with
 * Apple's WWDR OID and a leaf with the App Store's OID, made fresh (keys
 * in memory only), and JWS signed the way the App Store signs them.
 */
final class FakeApple {

    private static final AtomicLong SERIAL = new AtomicLong(1);

    final KeyPair rootKey = ec();
    final X509Certificate root;
    final KeyPair intermediateKey = ec();
    X509Certificate intermediate;
    final KeyPair leafKey = ec();
    X509Certificate leaf;

    FakeApple() {
        this(true, true, Instant.parse("2020-01-01T00:00:00Z"), Instant.parse("2040-01-01T00:00:00Z"));
    }

    FakeApple(boolean intermediateOid, boolean leafOid, Instant from, Instant until) {
        root = certificate("Fake Root", rootKey, "Fake Root", rootKey, true, null, from, until);
        intermediate = certificate("Fake WWDR", intermediateKey, "Fake Root", rootKey, true,
                intermediateOid ? AppleJws.INTERMEDIATE_OID : null, from, until);
        leaf = certificate("Fake App Store", leafKey, "Fake WWDR", intermediateKey, false,
                leafOid ? AppleJws.LEAF_OID : null, from, until);
    }

    /** A verifier that trusts this root. */
    AppleJws verifier() {
        return new AppleJws(root);
    }

    /** {@code payload} signed by the leaf, with the chain leaf, intermediate, root in x5c. */
    String sign(String payload) {
        return sign(payload, root);
    }

    /** The same with {@code x5cRoot} as the chain's third certificate. */
    String sign(String payload, X509Certificate x5cRoot) {
        try {
            var b64 = Base64.getEncoder();
            var header = "{\"alg\":\"ES256\",\"x5c\":[\"" + b64.encodeToString(leaf.getEncoded()) + "\",\""
                    + b64.encodeToString(intermediate.getEncoded()) + "\",\""
                    + b64.encodeToString(x5cRoot.getEncoded()) + "\"]}";
            var url = Base64.getUrlEncoder().withoutPadding();
            var input = url.encodeToString(header.getBytes(StandardCharsets.UTF_8)) + "."
                    + url.encodeToString(payload.getBytes(StandardCharsets.UTF_8));
            var signer = Signature.getInstance("SHA256withECDSAinP1363Format");
            signer.initSign(leafKey.getPrivate());
            signer.update(input.getBytes(StandardCharsets.US_ASCII));
            return input + "." + url.encodeToString(signer.sign());
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    /** A StoreKit 2 transaction's payload. */
    static String transaction(String bundleId, String productId, String original, Instant expires,
                              String environment, String accountToken, boolean revoked, Instant signed) {
        return "{\"transactionId\":\"" + original + "9\",\"originalTransactionId\":\"" + original
                + "\",\"bundleId\":\"" + bundleId + "\",\"productId\":\"" + productId
                + "\",\"type\":\"Auto-Renewable Subscription\",\"purchaseDate\":" + signed.minus(Duration.ofDays(1))
                .toEpochMilli() + ",\"expiresDate\":" + expires.toEpochMilli() + ",\"environment\":\"" + environment
                + "\",\"signedDate\":" + signed.toEpochMilli()
                + (accountToken == null ? "" : ",\"appAccountToken\":\"" + accountToken + "\"")
                + (revoked ? ",\"revocationDate\":" + signed.toEpochMilli() + ",\"revocationReason\":0" : "") + "}";
    }

    private static KeyPair ec() {
        try {
            var generator = KeyPairGenerator.getInstance("EC");
            generator.initialize(new ECGenParameterSpec("secp256r1"));
            return generator.generateKeyPair();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    private static X509Certificate certificate(String subject, KeyPair key, String issuer, KeyPair issuerKey,
                                               boolean ca, String oid, Instant from, Instant until) {
        try {
            var builder = new JcaX509v3CertificateBuilder(new X500Name("CN=" + issuer),
                    BigInteger.valueOf(SERIAL.getAndIncrement()), Date.from(from), Date.from(until),
                    new X500Name("CN=" + subject), key.getPublic());
            builder.addExtension(Extension.basicConstraints, true, new BasicConstraints(ca));
            builder.addExtension(Extension.keyUsage, true, new KeyUsage(ca
                    ? KeyUsage.keyCertSign | KeyUsage.cRLSign : KeyUsage.digitalSignature));
            if (oid != null) {
                builder.addExtension(new ASN1ObjectIdentifier(oid), false, DERNull.INSTANCE);
            }
            var signer = new JcaContentSignerBuilder("SHA256withECDSA").build(issuerKey.getPrivate());
            return new JcaX509CertificateConverter().getCertificate(builder.build(signer));
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }
}
