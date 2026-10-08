package presence.auth;

import java.util.Arrays;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * Decides a user's roles: none by default; every role ({@link #ROOT},
 * {@link #ADMIN} and {@link #USER}) for a verified email on the root
 * allowlist; plus whatever the roles table declares for the email, except
 * {@link #ROOT}, which only the allowlist gives. A subject linked to a
 * profile another account owns also gets {@link #USER} when the owner has
 * it (membership), never the owner's {@link #ADMIN} or {@link #ROOT}.
 * {@link #PREMIUM} comes only from {@link Rbacr rbacr}, for an email that
 * holds {@code premium} or {@code admin} in its {@code presence} system,
 * and a linked subject shares its owner's, as the profile's cloud folder is
 * one. Returned sorted.
 *
 * <p>The allowlist: a root <em>domain</em> ({@code PRESENCE_ROOT_DOMAINS})
 * counts only when the token's {@code hd} claim is that domain, i.e. the
 * account is managed by that Google Workspace. Anyone can register a
 * personal Google account with any address they can receive mail at
 * ({@code x@nu01.com}, verified once), so {@code email_verified} alone
 * doesn't prove the domain still vouches for it. A root <em>email</em>
 * ({@code PRESENCE_ROOT_EMAILS}) is matched whole, verified, without
 * {@code hd}: list only Gmail addresses, or addresses of a Workspace domain,
 * whose Google account can't be made by someone else.
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

    /**
     * Also syncs with the cloud (S3): its events, clips and settings go up
     * and come down, and its credentials are tagged so (see {@link
     * ProfileHandler}). Without it, a member's devices only tell each
     * other about events over live sync. Given by rbacr alone ({@link
     * #PREMIUM_FROM}), never by the roles table or the allowlist.
     */
    public static final String PREMIUM = "presence_premium";

    /** The rbacr roles (in the {@code presence} system) that give {@link #PREMIUM}. */
    static final Set<String> PREMIUM_FROM = Set.of("premium", "admin");

    /** What a root allowlist member gets. */
    static final Set<String> ROOT_ROLES = Set.of(ROOT, ADMIN, USER);

    /** Nobody signed in: may only sign in (or, in {@link ExecutionMode#DEV}, everything). */
    public static final String ANONYMOUS = "presence_anonymous";

    private final Set<String> rootDomains;
    private final Set<String> rootEmails;
    private final Function<String, Set<String>> declared;
    private final Function<String, Set<String>> rbacr;

    /** Without rbacr: nobody is {@link #PREMIUM}. */
    public Roles(Set<String> rootDomains, Set<String> rootEmails, Function<String, Set<String>> declared) {
        this(rootDomains, rootEmails, declared, email -> Set.of());
    }

    /**
     * @param rootDomains e.g. {@code nu01.com}; each matched exactly after the {@code @}, and against {@code hd}
     * @param rootEmails  single addresses, matched whole
     * @param declared    roles declared for a (lowercase) email, empty if none
     * @param rbacr       the email's roles in rbacr's {@code presence} system, empty if none (or unknown)
     */
    public Roles(Set<String> rootDomains, Set<String> rootEmails, Function<String, Set<String>> declared,
                 Function<String, Set<String>> rbacr) {
        this.rootDomains = normalized(rootDomains);
        this.rootEmails = normalized(rootEmails);
        this.declared = declared;
        this.rbacr = rbacr;
    }

    /** From the function's environment (see template.yaml): the allowlist, the UserRoles table and rbacr. */
    static Roles fromEnvironment() {
        var table = System.getenv("USER_ROLES_TABLE");
        var dynamo = Aws.dynamo();
        return new Roles(list(System.getenv("PRESENCE_ROOT_DOMAINS")), list(System.getenv("PRESENCE_ROOT_EMAILS")),
                email -> UserRoles.declared(dynamo, table, email), Rbacr.fromEnvironment());
    }

    /** A comma-separated setting's non-blank items. */
    static Set<String> list(String value) {
        return Arrays.stream(value == null ? new String[0] : value.split(","))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .collect(Collectors.toSet());
    }

    private static Set<String> normalized(Set<String> values) {
        return values.stream()
                .map(d -> d.trim().toLowerCase(Locale.ROOT))
                .filter(d -> !d.isEmpty())
                .collect(Collectors.toUnmodifiableSet());
    }

    /**
     * The roles for {@code email} alone.
     *
     * @param emailVerified the token's {@code email_verified} claim
     * @param hd            the token's {@code hd} claim (its Workspace domain), null if none
     */
    public Set<String> of(String email, boolean emailVerified, String hd) {
        var roles = new TreeSet<String>();
        if (email == null || email.isBlank() || !emailVerified) {
            return roles;
        }
        var normalized = email.trim().toLowerCase(Locale.ROOT);
        var at = normalized.lastIndexOf('@');
        var domain = at > 0 ? normalized.substring(at + 1) : "";
        var workspace = hd == null ? "" : hd.trim().toLowerCase(Locale.ROOT);
        if (rootEmails.contains(normalized) || rootDomains.contains(domain) && domain.equals(workspace)) {
            roles.addAll(ROOT_ROLES);
        }
        // Premium is rbacr's to give, not the table's.
        declared.apply(normalized).stream().filter(r -> !ROOT.equals(r) && !PREMIUM.equals(r)).forEach(roles::add);
        if (rbacr.apply(normalized).stream().anyMatch(PREMIUM_FROM::contains)) {
            roles.add(PREMIUM);
        }
        return roles;
    }

    /** The caller's own roles. */
    public Set<String> of(Caller caller) {
        return of(caller.email(), caller.verified(), caller.hd());
    }

    /**
     * The caller's roles, plus {@link #USER} when its account is linked to
     * {@code profile} (null when none), owned by another account that is a
     * member: one person, whichever of their accounts signs in, uses the
     * app; and {@link #PREMIUM} when the owner has it, as the profile's
     * cloud folder is the owner's. Administration ({@link #ADMIN}, {@link
     * #ROOT}) is never shared: each account gets it only from its own email.
     */
    public Set<String> of(Caller caller, Profiles.Profile profile) {
        var roles = new TreeSet<>(of(caller));
        if (profile == null || !caller.verified() || profile.ownerEmail() == null
                || profile.ownerSubject() != null && profile.ownerSubject().equals(caller.subject())) {
            return roles;
        }
        // The owner's email was verified when stored (Profiles keeps no other).
        var owner = of(profile.ownerEmail(), true, profile.ownerHd());
        if (owner.contains(USER)) {
            roles.add(USER);
        }
        if (owner.contains(PREMIUM)) {
            roles.add(PREMIUM);
        }
        return roles;
    }

    /** The anonymous user's roles: only {@link #ANONYMOUS}, or every role in {@link ExecutionMode#DEV}. */
    public static Set<String> anonymous(ExecutionMode mode) {
        var roles = new TreeSet<String>();
        roles.add(ANONYMOUS);
        if (mode == ExecutionMode.DEV) {
            roles.addAll(ROOT_ROLES);
            roles.add(PREMIUM);
        }
        return roles;
    }
}
