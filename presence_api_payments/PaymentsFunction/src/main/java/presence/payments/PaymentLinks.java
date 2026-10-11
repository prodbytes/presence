package presence.payments;

import java.net.URI;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * The Stripe Payment Links of the Premium subscription, monthly and
 * yearly. Each is an HTTPS link on {@code stripe.com} (such as {@code
 * https://buy.stripe.com/...}), or empty when that plan isn't offered.
 *
 * @param monthly   the monthly plan's link, or empty
 * @param yearly    the yearly plan's link, or empty
 * @param updatedAt when an admin saved them (epoch ms), or 0 for the
 *                  deploy's defaults
 * @param updatedBy who saved them (an admin's email), or null; kept in the
 *                  table, never answered
 */
record PaymentLinks(String monthly, String yearly, long updatedAt, String updatedBy) {

    /** The longest link taken. */
    static final int MAX_LENGTH = 512;

    /**
     * An HTTPS link on stripe.com or a subdomain, with a path of URL-safe
     * characters only (no query, no quotes or backslashes, so it goes into
     * JSON as it is).
     */
    private static final Pattern LINK = Pattern.compile(
            "https://(?:[a-z0-9-]+\\.)*stripe\\.com(?:/[A-Za-z0-9._~%-]*)*");

    /** The deploy's defaults ({@code MONTHLY_LINK}, {@code YEARLY_LINK}; empty when not links). */
    static PaymentLinks defaults(String monthly, String yearly) {
        return new PaymentLinks(orEmpty(monthly), orEmpty(yearly), 0, null);
    }

    /** Whether {@code link} is one this takes: empty (not offered), or a Stripe HTTPS link. */
    static boolean valid(String link) {
        if (link == null) {
            return false;
        }
        if (link.isEmpty()) {
            return true;
        }
        if (link.length() > MAX_LENGTH || !LINK.matcher(link).matches()) {
            return false;
        }
        var host = URI.create(link).getHost();
        return host != null && (host.equals("stripe.com") || host.endsWith(".stripe.com"));
    }

    private static String orEmpty(String link) {
        var stripped = link == null ? "" : link.strip();
        return valid(stripped) ? stripped : "";
    }

    /** Whether an admin saved them (else they're the deploy's defaults). */
    boolean saved() {
        return updatedAt > 0;
    }

    /** As answered: {@code {"monthly":"...","yearly":"...","saved":true,"updatedAt":...}}. */
    String toJson() {
        return "{\"monthly\":" + Json.string(monthly) + ",\"yearly\":" + Json.string(yearly)
                + ",\"saved\":" + saved() + (saved() ? ",\"updatedAt\":" + updatedAt : "") + "}";
    }

    private static final Pattern ENTRY = Pattern.compile("\\s*\"([a-z]{1,16})\"\\s*:\\s*\"([^\"\\\\]*)\"\\s*(,|$)");

    /**
     * The links in a request body, {@code {"monthly": "...", "yearly":
     * "..."}}: both keys, no others, plain strings (no escapes). Null when
     * it isn't that; the links aren't checked here ({@link #valid}).
     */
    static Map<String, String> parse(String body) {
        if (body == null) {
            return null;
        }
        var text = body.strip();
        if (!text.startsWith("{") || !text.endsWith("}")) {
            return null;
        }
        var entries = text.substring(1, text.length() - 1);
        var found = new HashMap<String, String>();
        var entry = ENTRY.matcher(entries);
        var at = 0;
        while (at < entries.length() && !entries.substring(at).isBlank()) {
            if (!entry.find(at) || entry.start() != at) {
                return null;
            }
            var key = entry.group(1);
            if (!key.equals("monthly") && !key.equals("yearly") || found.put(key, entry.group(2)) != null) {
                return null;
            }
            at = entry.end();
        }
        return found.size() == 2 ? found : null;
    }
}
