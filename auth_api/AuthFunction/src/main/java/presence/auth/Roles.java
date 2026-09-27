package presence.auth;

import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.Function;

/**
 * Decides a user's roles: none by default; the domain roles for a verified
 * email at the privileged domain; plus whatever the roles table declares
 * for the email. Returned sorted.
 */
public final class Roles {

    private final String privilegedDomain;
    private final Set<String> domainRoles;
    private final Function<String, Set<String>> declared;

    /**
     * @param privilegedDomain e.g. {@code nu01.com}; matched exactly after the {@code @}
     * @param domainRoles      roles for verified emails at that domain
     * @param declared         roles declared for a (lowercase) email, empty if none
     */
    public Roles(String privilegedDomain, Set<String> domainRoles, Function<String, Set<String>> declared) {
        this.privilegedDomain = privilegedDomain.trim().toLowerCase(Locale.ROOT);
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
        if (at > 0 && normalized.substring(at + 1).equals(privilegedDomain)) {
            roles.addAll(domainRoles);
        }
        roles.addAll(declared.apply(normalized));
        return roles;
    }
}
