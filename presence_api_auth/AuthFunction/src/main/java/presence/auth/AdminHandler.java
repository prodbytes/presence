package presence.auth;

import com.amazonaws.services.lambda.runtime.Context;
import com.amazonaws.services.lambda.runtime.RequestHandler;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayV2HTTPResponse;
import software.amazon.awssdk.services.dynamodb.model.AttributeValue;
import software.amazon.awssdk.services.dynamodb.model.ConditionalCheckFailedException;
import software.amazon.awssdk.services.dynamodb.model.DeleteItemRequest;
import software.amazon.awssdk.services.dynamodb.model.ScanRequest;
import software.amazon.awssdk.services.dynamodb.model.UpdateItemRequest;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.format.DateTimeParseException;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.Function;
import java.util.stream.Collectors;

import static presence.auth.Attrs.instant;
import static presence.auth.Attrs.text;
import static presence.auth.Http.response;

/**
 * The Admin screen's API, for users with both {@code presence_user} and
 * {@code presence_admin} (403 otherwise, as the app shows the screen):
 * <ul>
 *   <li>{@code GET /api/auth/membership}: the pending membership requests,
 *       oldest first, as {@code {"requests": [{email, name, message, requestedAt}]}};</li>
 *   <li>{@code POST /api/auth/membership/grant}: gives the email in the
 *       (plain-text) body the {@code presence_user} role (an rbacr grant
 *       of {@code free}, {@link Roles#GRANTED_AS}) and drops its request;</li>
 *   <li>{@code POST /api/auth/membership/dismiss}: hides the email's request.
 *       It stays in the table, so the requester's cooldown still holds;</li>
 *   <li>{@code GET /api/auth/vouchers}: every voucher, newest first, as
 *       {@code {"vouchers": [{code, role, startsAt, expiresAt, maxUses, uses, redeemedBy,
 *       createdBy, createdAt, discount}]}}. A presence_admin voucher's code
 *       is shown only to a {@code presence_root} caller: to others it is
 *       {@code null}, with {@code "hidden": true}, so an admin can't pass
 *       the role on;</li>
 *   <li>{@code POST /api/auth/vouchers}: creates a voucher from the
 *       form-encoded body {@code role}, {@code expiresAt} (ISO-8601, in the
 *       future, within {@link #MAX_VALIDITY}), {@code maxUses} (1 to
 *       {@link VoucherHandler#MAX_USES}), and optionally {@code startsAt}
 *       (ISO-8601, before {@code expiresAt}, at most {@link #MAX_VALIDITY}
 *       ago; now if absent), {@code code} (see
 *       {@link VoucherHandler#chosen}: at least {@link VoucherHandler#MIN_CHOSEN}
 *       letters and digits; random if absent or blank, 409 if taken) and
 *       {@code discount} (percent, 1 to 100; 100 if absent), and answers it.
 *       A {@code presence_admin} voucher needs a {@code presence_root} caller
 *       (403 otherwise) and a random code (400 for a chosen one);</li>
 *   <li>{@code POST /api/auth/vouchers/delete}: deletes the voucher whose code
 *       is the body; a presence_admin one only for a {@code presence_root}
 *       caller (403 otherwise);</li>
 *   <li>{@code GET /api/auth/maintenance}: the {@link Maintenance} state
 *       (rbacr's flag, on when rbacr can't say), with the last switch made
 *       here and who made it, as {@code {on, message, since, reason, by,
 *       rbacr}};</li>
 *   <li>{@code POST /api/auth/maintenance}: for a {@code presence_root}
 *       only (403 otherwise: in maintenance rbacr gives admins no role, so
 *       only a root could switch it off), switches rbacr's flag, from the
 *       form-encoded body {@code on} ({@code true} or {@code false}) and
 *       optionally {@code message} (up to {@link Maintenance#MAX_MESSAGE}
 *       characters), and answers the new state.</li>
 * </ul>
 * A linked account shares its profile owner's membership, never the
 * owner's administration: the caller's own email must make it an admin.
 */
public class AdminHandler implements RequestHandler<APIGatewayV2HTTPEvent, APIGatewayV2HTTPResponse> {

    /** Where membership requests are kept, and roles granted. */
    interface Backend {
        /** The requests that weren't dismissed. */
        List<MembershipHandler.Request> requests();

        /** Grants the email {@code role} (one of {@link Roles#GRANTED_AS}'s) in rbacr. */
        void grant(String email, String role);

        /** Removes the email's request (after a grant). */
        void remove(String email);

        /** Hides the email's request from {@link #requests()}. */
        void dismiss(String email);
    }

    /** The furthest a voucher may expire. */
    static final Duration MAX_VALIDITY = Duration.ofDays(366);

    private final Roles roles;
    private final Function<String, Profiles.Profile> linked;
    private final Backend backend;
    private final VoucherHandler.Store vouchers;
    private final Maintenance.Store maintenance;
    private final Maintenance.Flag flag;
    private final Clock clock;

    /** Lambda's entry point: configured from the environment (see template.yaml). */
    public AdminHandler() {
        this(Roles.fromEnvironment(), Profiles.fromEnvironment()::existing,
                dynamoBackend(System.getenv("MEMBERSHIP_TABLE"), Rbacr.fromEnvironment()),
                VoucherHandler.dynamoStore(System.getenv("VOUCHER_TABLE")),
                Maintenance.dynamoStore(System.getenv("SYSTEM_TABLE")),
                Maintenance.rbacr(Rbacr.fromEnvironment()),
                Clock.systemUTC());
    }

    AdminHandler(Roles roles, Backend backend, VoucherHandler.Store vouchers, Clock clock) {
        this(roles, subject -> null, backend, vouchers, clock);
    }

    /**
     * @param linked for a subject, the profile it's linked to, without making one
     *               ({@link Profiles#existing}): a linked subject shares the owner's membership
     */
    AdminHandler(Roles roles, Function<String, Profiles.Profile> linked, Backend backend,
                 VoucherHandler.Store vouchers, Clock clock) {
        this(roles, linked, backend, vouchers, Maintenance.memory(), Maintenance.memoryFlag(), clock);
    }

    /** @param flag rbacr's maintenance flag on the system */
    AdminHandler(Roles roles, Function<String, Profiles.Profile> linked, Backend backend,
                 VoucherHandler.Store vouchers, Maintenance.Store maintenance, Maintenance.Flag flag,
                 Clock clock) {
        this.roles = roles;
        this.linked = linked;
        this.backend = backend;
        this.vouchers = vouchers;
        this.maintenance = maintenance;
        this.flag = flag;
        this.clock = clock;
    }

    @Override
    public APIGatewayV2HTTPResponse handleRequest(APIGatewayV2HTTPEvent event, Context context) {
        var route = Http.route(event);
        try {
            return handle(event, route);
        } catch (RuntimeException e) {
            return Aws.failed("admin", route, e, context);
        }
    }

    private APIGatewayV2HTTPResponse handle(APIGatewayV2HTTPEvent event, String route) {
        var caller = Caller.from(event);
        var callerRoles = roles.of(caller, caller.hasSubject() ? linked.apply(caller.subject()) : null);
        if (!callerRoles.contains(Roles.USER) || !callerRoles.contains(Roles.ADMIN)) {
            return response(403, "{\"error\":\"administrators only\"}");
        }
        var root = callerRoles.contains(Roles.ROOT);
        return switch (route) {
            case "GET /api/auth/membership" -> response(200, "{\"requests\":["
                    + backend.requests().stream()
                    .sorted(Comparator.comparing(MembershipHandler.Request::requestedAt))
                    .map(AdminHandler::json)
                    .collect(Collectors.joining(","))
                    + "]}");
            case "POST /api/auth/membership/grant", "POST /api/auth/membership/dismiss" -> {
                var body = Http.bodyText(event, 254);
                var email = body == null ? "" : body.toLowerCase(Locale.ROOT);
                if (!validEmail(email)) {
                    yield response(400, "{\"error\":\"the body must be an email\"}");
                }
                if (route.endsWith("/grant")) {
                    backend.grant(email, Roles.USER);
                    backend.remove(email);
                } else {
                    backend.dismiss(email);
                }
                yield response(200, "{\"email\":" + Json.string(email) + "}");
            }
            // Only roots see presence_admin codes: an admin can't hand the role on.
            case "GET /api/auth/vouchers" -> response(200, "{\"vouchers\":["
                    + vouchers.all().stream()
                    .sorted(Comparator.comparing(VoucherHandler.Voucher::createdAt).reversed())
                    .map(v -> v.toJson(root || !Roles.ADMIN.equals(v.role())))
                    .collect(Collectors.joining(","))
                    + "]}");
            // Roles need a verified email, so an admin has one.
            case "POST /api/auth/vouchers" -> createVoucher(event, caller.verifiedEmail(), root);
            case "POST /api/auth/vouchers/delete" -> {
                var body = Http.bodyText(event, 64);
                var code = body == null ? null : VoucherHandler.normalize(body);
                if (code == null) {
                    yield response(400, "{\"error\":\"the body must be a voucher code\"}");
                }
                if (!vouchers.delete(code, root)) {
                    yield response(403, "{\"error\":\"only presence_root deletes presence_admin vouchers\"}");
                }
                yield response(200, "{\"code\":" + Json.string(code) + "}");
            }
            case "GET /api/auth/maintenance" -> response(200, maintenance.get().toJson(flag.get()));
            case "POST /api/auth/maintenance" -> root
                    ? setMaintenance(event, caller.verifiedEmail())
                    : response(403, "{\"error\":\"only presence_root switches maintenance mode\"}");
            default -> response(404, "{\"error\":\"no such route\"}");
        };
    }

    private APIGatewayV2HTTPResponse createVoucher(APIGatewayV2HTTPEvent event, String createdBy, boolean root) {
        var body = Http.bodyText(event, 1000);
        var form = VoucherHandler.form(body == null ? "" : body);
        var role = form.getOrDefault("role", "");
        if (!VoucherHandler.ROLES.contains(role)) {
            return response(400, "{\"error\":\"role must be one of " + String.join(", ", new TreeSet<>(VoucherHandler.ROLES)) + "\"}");
        }
        // Only roots make admins: an admin can't pass the role on.
        if (Roles.ADMIN.equals(role) && !root) {
            return response(403, "{\"error\":\"only presence_root creates presence_admin vouchers\"}");
        }
        // Milliseconds, as stored.
        var now = clock.instant().truncatedTo(ChronoUnit.MILLIS);
        Instant expiresAt;
        try {
            expiresAt = Instant.parse(form.getOrDefault("expiresAt", ""));
        } catch (DateTimeParseException e) {
            return response(400, "{\"error\":\"expiresAt must be an ISO-8601 instant\"}");
        }
        if (!expiresAt.isAfter(now) || expiresAt.isAfter(now.plus(MAX_VALIDITY))) {
            return response(400, "{\"error\":\"expiresAt must be in the future, within "
                    + MAX_VALIDITY.toDays() + " days\"}");
        }
        // Valid from now, unless the admin picked a start (in the past too:
        // the start of the season).
        var startsAt = now;
        var start = form.getOrDefault("startsAt", "");
        if (!start.isBlank()) {
            try {
                startsAt = Instant.parse(start).truncatedTo(ChronoUnit.MILLIS);
            } catch (DateTimeParseException e) {
                return response(400, "{\"error\":\"startsAt must be an ISO-8601 instant\"}");
            }
            if (!startsAt.isBefore(expiresAt) || startsAt.isBefore(now.minus(MAX_VALIDITY))) {
                return response(400, "{\"error\":\"startsAt must be before expiresAt, within "
                        + MAX_VALIDITY.toDays() + " days ago\"}");
            }
        }
        int maxUses;
        try {
            maxUses = Integer.parseInt(form.getOrDefault("maxUses", ""));
        } catch (NumberFormatException e) {
            maxUses = 0;
        }
        if (maxUses < 1 || maxUses > VoucherHandler.MAX_USES) {
            return response(400, "{\"error\":\"maxUses must be 1 to " + VoucherHandler.MAX_USES + "\"}");
        }
        int discount;
        try {
            discount = Integer.parseInt(form.getOrDefault("discount", "" + VoucherHandler.FULL_DISCOUNT));
        } catch (NumberFormatException e) {
            discount = 0;
        }
        if (discount < 1 || discount > VoucherHandler.FULL_DISCOUNT) {
            return response(400, "{\"error\":\"discount must be 1 to 100 (percent)\"}");
        }
        var chosen = form.getOrDefault("code", "");
        if (!chosen.isBlank()) {
            // The code is an Admin voucher's only secret: never a guessable one.
            if (Roles.ADMIN.equals(role)) {
                return response(400, "{\"error\":\"presence_admin vouchers get a random code\"}");
            }
            var code = VoucherHandler.chosen(chosen);
            if (code == null) {
                return response(400, "{\"error\":\"code must be " + VoucherHandler.MIN_CHOSEN + " to "
                        + VoucherHandler.MAX_CODE + " letters and digits, with dashes between words\"}");
            }
            var voucher = new VoucherHandler.Voucher(code, role, startsAt, expiresAt, maxUses, 0,
                    Set.of(), createdBy, now, discount);
            return vouchers.create(voucher)
                    ? response(201, voucher.toJson())
                    : response(409, "{\"error\":\"that code is taken\"}");
        }
        // 60 random bits rarely collide; try again if one does.
        for (var attempt = 0; attempt < 3; attempt++) {
            var voucher = new VoucherHandler.Voucher(VoucherHandler.newCode(), role, startsAt, expiresAt, maxUses, 0,
                    Set.of(), createdBy, now, discount);
            if (vouchers.create(voucher)) {
                return response(201, voucher.toJson());
            }
        }
        return response(500, "{\"error\":\"couldn't pick a free code\"}");
    }

    private APIGatewayV2HTTPResponse setMaintenance(APIGatewayV2HTTPEvent event, String by) {
        var body = Http.bodyText(event, 12 * Maintenance.MAX_MESSAGE);
        var form = VoucherHandler.form(body == null ? "" : body);
        var on = form.getOrDefault("on", "");
        if (!on.equals("true") && !on.equals("false")) {
            return response(400, "{\"error\":\"on must be true or false\"}");
        }
        var message = Maintenance.cleanMessage(form.get("message"));
        if (message == null) {
            return response(400, "{\"error\":\"message must be at most " + Maintenance.MAX_MESSAGE
                    + " characters\"}");
        }
        var state = new Maintenance(on.equals("true"), message,
                clock.instant().truncatedTo(ChronoUnit.MILLIS), by == null ? "" : by);
        // rbacr first: it decides; then the message, which only goes with it.
        flag.set(state.on());
        maintenance.set(state);
        System.err.println("presence: maintenance mode " + (state.on() ? "on" : "off") + " by " + state.by());
        return response(200, state.toJson(state.on()));
    }

    /** One address: something@domain, at most 254 characters, no spaces or commas. */
    static boolean validEmail(String email) {
        var at = email.lastIndexOf('@');
        return email.length() <= 254 && at > 0 && at < email.length() - 1
                && email.chars().noneMatch(c -> c <= ' ' || c == ',');
    }

    static String json(MembershipHandler.Request r) {
        return "{\"email\":" + Json.string(r.email())
                + ",\"name\":" + Json.string(r.name())
                + ",\"message\":" + Json.string(r.message())
                + ",\"requestedAt\":" + Json.string(r.requestedAt().toString()) + "}";
    }

    /** Requests in {@code membershipTable}, grants in {@code rbacr}. */
    static Backend dynamoBackend(String membershipTable, Rbacr rbacr) {
        var dynamo = Aws.dynamo();
        return new Backend() {
            @Override
            public List<MembershipHandler.Request> requests() {
                var result = new ArrayList<MembershipHandler.Request>();
                // Few requests are ever pending; the paginator reads them all.
                var scan = ScanRequest.builder()
                        .tableName(membershipTable)
                        .filterExpression("attribute_not_exists(dismissed)")
                        .build();
                for (var page : dynamo.scanPaginator(scan)) {
                    for (var item : page.items()) {
                        result.add(new MembershipHandler.Request(
                                text(item, "email"), text(item, "name"), text(item, "message"),
                                instant(item.getOrDefault("requestedAt", AttributeValue.fromN("0")))));
                    }
                }
                return result;
            }

            @Override
            public void grant(String email, String role) {
                rbacr.grant(email, Roles.GRANTED_AS.get(role));
            }

            @Override
            public void remove(String email) {
                dynamo.deleteItem(DeleteItemRequest.builder()
                        .tableName(membershipTable)
                        .key(Map.of("email", AttributeValue.fromS(email)))
                        .build());
            }

            @Override
            public void dismiss(String email) {
                try {
                    dynamo.updateItem(UpdateItemRequest.builder()
                            .tableName(membershipTable)
                            .key(Map.of("email", AttributeValue.fromS(email)))
                            .updateExpression("SET dismissed = :yes")
                            // Don't create a row for an email that never asked.
                            .conditionExpression("attribute_exists(email)")
                            .expressionAttributeValues(Map.of(":yes", AttributeValue.fromBool(true)))
                            .build());
                } catch (ConditionalCheckFailedException e) {
                    // Already gone: nothing to dismiss.
                }
            }
        };
    }
}
