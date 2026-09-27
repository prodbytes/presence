package presence.auth;

import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Decides a user's roles: none by default; the domain roles for a verified
 * email at one of the allowed domains; plus whatever the roles table
 * declares for the email. Returned sorted.
 */
public final class Roles {

    /** Uses the app. */
    public static final String USER = "presence_user";

    /** Also grants other users access. */
    public static final String ADMIN = "presence_admin";

    private final Set<String> allowedDomains;
    private final Set<String> domainRoles;
    private final Function<String, Set<String>> declared;

    /**
     * @param allowedDomains e.g. {@code nu01.com}; each matched exactly after the {@code @}
     * @param domainRoles    roles for verified emails at those domains
     * @param declared       roles declared for a (lowercase) email, empty if none
     */
    public Roles(Set<String> allowedDomains, Set<String> domainRoles, Function<String, Set<String>> declared) {
        this.allowedDomains = allowedDomains.stream()
                .map(d -> d.trim().toLowerCase(Locale.ROOT))
                .filter(d -> !d.isEmpty())
                .collect(Collectors.toUnmodifiableSet());
        this.domainRoles = Set.copyOf(domainRoles);
        this.declared = declared;
    }

    /** The roles for {@code email}; {@code emailVerified} is the token's {@code email_verified} claim. */
    public Set<String> of(String email, boolean emailVerified) {
        var roles = new TreeSet<String>();
        if (email == null || email.isBlank() || !emailVerified) {
            return roles;
        }
        var normalized = email.trim().toLowerCase(Locale.ROOT);
        var at = normalized.lastIndexOf('@');
        if (at > 0 && allowedDomains.contains(normalized.substring(at + 1))) {
            roles.addAll(domainRoles);
        }
        roles.addAll(declared.apply(normalized));
        return roles;
    }
}
