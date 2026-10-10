package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.awscore.exception.AwsServiceException;
import software.amazon.awssdk.http.SdkHttpClient;
import software.amazon.awssdk.http.urlconnection.UrlConnectionHttpClient;
import software.amazon.awssdk.services.dynamodb.DynamoDbClient;

import java.util.Optional;

/**
 * The AWS clients a function shares, and how a handler answers when AWS
 * fails. One HTTP client and one DynamoDB client per function instance,
 * made at first use (in Lambda's init phase, from a handler's
 * constructor), however many tables and stores use them.
 */
final class Aws {

    private Aws() {
    }

    /** Lazily made, once per function instance. */
    private static final class Holder {
        static final SdkHttpClient HTTP = UrlConnectionHttpClient.create();
        static final DynamoDbClient DYNAMO = DynamoDbClient.builder().httpClient(HTTP).build();
    }

    /** The function's HTTP client, for every AWS SDK client. */
    static SdkHttpClient http() {
        return Holder.HTTP;
    }

    /** The function's DynamoDB client. */
    static DynamoDbClient dynamo() {
        return Holder.DYNAMO;
    }

    /**
     * A handler's answer when AWS (or anything else) failed: 502 with
     * {@code what} failed, the {@link #cause} and the request ID that finds
     * the full error in the log, but not AWS's message, which names ARNs.
     */
    static APIGatewayV2HTTPResponse failed(String what, String route, RuntimeException e, Context context) {
        var requestId = context == null ? null : context.getAwsRequestId();
        System.err.println("presence: " + route + " failed (request " + requestId + "): " + cause(e) + ": " + e);
        return Http.response(502, "{\"error\":" + Json.string("the " + what + " service failed")
                + ",\"cause\":" + Json.string(cause(e))
                + (requestId == null ? "" : ",\"requestId\":" + Json.string(requestId)) + "}");
    }

    /**
     * What failed, for the caller: an AWS service, the operation (when the
     * SDK client called it) and its error code, or the exception's type.
     */
    static String cause(RuntimeException e) {
        if (e instanceof AwsServiceException aws && aws.awsErrorDetails() != null) {
            var details = aws.awsErrorDetails();
            var cause = details.serviceName() + operation(e).map(op -> " " + op + ":").orElse("")
                    + " " + details.errorCode() + " (HTTP " + aws.statusCode() + ")";
            // AWS knows every operation the SDK sends; an endpoint that
            // doesn't is an emulator, such as Floci in the local stack, which
            // has no Cognito Identity. Say so, and where it does work.
            if ("UnknownOperationException".equals(details.errorCode())) {
                cause += "; the endpoint doesn't implement it: a local AWS emulator (Floci,"
                        + " in the local stack) has no " + details.serviceName()
                        + ", so this works only against AWS (the RC or production)";
            }
            return cause;
        }
        return e.getClass().getSimpleName();
    }

    /**
     * The AWS operation that threw {@code e}: the SDK client's method in its
     * stack trace ({@code DefaultCognitoIdentityClient.getId} is
     * {@code GetId}), if it's there.
     */
    static Optional<String> operation(Throwable e) {
        for (var frame : e.getStackTrace()) {
            var type = frame.getClassName();
            if (type.startsWith("software.amazon.awssdk.services.")
                    && type.substring(type.lastIndexOf('.') + 1).startsWith("Default")
                    && type.endsWith("Client")) {
                var method = frame.getMethodName();
                return Optional.of(Character.toUpperCase(method.charAt(0)) + method.substring(1));
            }
        }
        return Optional.empty();
    }
}
