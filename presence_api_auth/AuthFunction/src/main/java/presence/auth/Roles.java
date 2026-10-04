package presence.auth;

import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Decides a user's roles: none by default; every role ({@link #ROOT},
 * {@link #ADMIN} and {@link #USER}) for a verified email on the root
 * allowlist (one of its domains, or one of its emails); plus whatever the
 * roles table declares for the email, except {@link #ROOT}, which only the
 * allowlist gives. Returned sorted.
 */
public final class Roles {

    /** Uses the app. */
    public static final String USER = "presence_user";

    /** Also grants other users access, and creates vouchers for {@link #USER}. */
    public static final String ADMIN = "presence_admin";

    /**
     * On the root allowlist ({@code PRESENCE_ROOT_DOMAINS},
     * {@code PRESENCE_ROOT_EMAILS}): also creates vouchers for {@link #ADMIN},
     * so only roots make admins. Nothing grants it but the allowlist.
     */
    public static final String ROOT = "presence_root";

    /** What a root allowlist member gets. */
    static final Set<String> ROOT_ROLES = Set.of(ROOT, ADMIN, USER);

    /** Nobody signed in: may only sign in (or, in {@link ExecutionMode#DEV}, everything). */
    public static final String ANONYMOUS = "presence_anonymous";

    private final Set<String> rootDomains;
    private final Set<String> rootEmails;
    private final Function<String, Set<String>> declared;

    /**
     * @param rootDomains e.g. {@code nu01.com}; each matched exactly after the {@code @}
     * @param rootEmails  single addresses, matched whole
     * @param declared    roles declared for a (lowercase) email, empty if none
     */
    public Roles(Set<String> rootDomains, Set<String> rootEmails, Function<String, Set<String>> declared) {
        this.rootDomains = normalized(rootDomains);
        this.rootEmails = normalized(rootEmails);
        this.declared = declared;
    }

    private static Set<String> normalized(Set<String> values) {
        return values.stream()
                .map(d -> d.trim().toLowerCase(Locale.ROOT))
                .filter(d -> !d.isEmpty())
                .collect(Collectors.toUnmodifiableSet());
    }

    /** The roles for {@code email}; {@code emailVerified} is the token's {@code email_verified} claim. */
    public Set<String> of(String email, boolean emailVerified) {
        var roles = new TreeSet<String>();
        if (email == null || email.isBlank() || !emailVerified) {
            return roles;
        }
        var normalized = email.trim().toLowerCase(Locale.ROOT);
        var at = normalized.lastIndexOf('@');
        if (rootEmails.contains(normalized) || at > 0 && rootDomains.contains(normalized.substring(at + 1))) {
            roles.addAll(ROOT_ROLES);
        }
        declared.apply(normalized).stream().filter(r -> !ROOT.equals(r)).forEach(roles::add);
        return roles;
    }

    /**
     * The roles for {@code email} plus, when its account is linked to a
     * profile another account owns, the owner's: one person, the same roles
     * whichever of their accounts signs in. {@code ownerEmail} (null when
     * none) was verified when the profile was made.
     */
    public Set<String> of(String email, boolean emailVerified, String ownerEmail) {
        var roles = new TreeSet<>(of(email, emailVerified));
        if (emailVerified && ownerEmail != null && !ownerEmail.equalsIgnoreCase(email == null ? "" : email.trim())) {
            roles.addAll(of(ownerEmail, true));
        }
        return roles;
    }

    /** The anonymous user's roles: only {@link #ANONYMOUS}, or every role in {@link ExecutionMode#DEV}. */
    public static Set<String> anonymous(ExecutionMode mode) {
        var roles = new TreeSet<String>();
        roles.add(ANONYMOUS);
        if (mode == ExecutionMode.DEV) {
            roles.addAll(ROOT_ROLES);
        }
        return roles;
    }
}
