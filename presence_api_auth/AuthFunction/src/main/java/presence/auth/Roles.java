package presence.auth;

import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.Function;

/**
 * Decides a user's roles from {@link Rbacr rbacr}, the only place roles are
 * kept: none by default, and for a verified email, the app's roles for what
 * rbacr gives it in the {@code presence} system:
 * <ul>
 *   <li>{@link #USER} for {@code free}, {@code premium} or {@code admin};</li>
 *   <li>{@link #PREMIUM} for {@code premium} or {@code admin};</li>
 *   <li>{@link #ADMIN} for {@code admin};</li>
 *   <li>{@link #ROOT}, and with it every role ({@link #ROOT_ROLES}), for an
 *       rbacr root (rbacr's root list).</li>
 * </ul>
 * (rbacr's implications, {@code admin → premium → free}, give the same, but
 * the mapping doesn't count on them.) A subject linked to a profile another
 * account owns also gets {@link #USER} and {@link #PREMIUM} when the owner
 * has them, never the owner's {@link #ADMIN} or {@link #ROOT}
 * ({@link #shared}). Returned sorted.
 */
public final class Roles {

    /** Uses the app. */
    public static final String USER = "presence_user";

    /** Administers the app (in rbacr, where admins also manage vouchers and maintenance). */
    public static final String ADMIN = "presence_admin";

    /** An rbacr root (rbacr's root list). Nothing in presence grants it. */
    public static final String ROOT = "presence_root";

    /**
     * Also syncs with the cloud (S3): its events, clips and settings go up
     * and come down, and its credentials are tagged so (see {@link
     * ProfileHandler}). Without it, a member's devices only tell each
     * other about events over live sync.
     */
    public static final String PREMIUM = "presence_premium";

    /** For each of the app's roles, the rbacr roles (in the {@code presence} system) that give it. */
    static final Map<String, Set<String>> FROM = Map.of(
            USER, Set.of("free", "premium", "admin"),
            PREMIUM, Set.of("premium", "admin"),
            ADMIN, Set.of("admin"));

    /** What an rbacr root gets. */
    static final Set<String> ROOT_ROLES = Set.of(ROOT, ADMIN, USER, PREMIUM);

    /** Nobody signed in: may only sign in (or, in {@link ExecutionMode#DEV}, everything). */
    public static final String ANONYMOUS = "presence_anonymous";

    private final Function<String, Set<String>> rbacr;

    /**
     * @param rbacr an email's (lowercase) roles in rbacr's {@code presence}
     *              system, plus {@link Rbacr#ROOT} for a root; empty if none
     *              (or unknown)
     */
    public Roles(Function<String, Set<String>> rbacr) {
        this.rbacr = rbacr;
    }

    /** From the function's environment (see template.yaml): rbacr. */
    static Roles fromEnvironment() {
        return new Roles(Rbacr.fromEnvironment());
    }

    /**
     * The roles for {@code email} alone.
     *
     * @param emailVerified the token's {@code email_verified} claim: rbacr is asked only about verified emails
     */
    public Set<String> of(String email, boolean emailVerified) {
        var roles = new TreeSet<String>();
        if (email == null || email.isBlank() || !emailVerified) {
            return roles;
        }
        var held = rbacr.apply(email.trim().toLowerCase(Locale.ROOT));
        if (held.contains(Rbacr.ROOT)) {
            roles.addAll(ROOT_ROLES);
        }
        FROM.forEach((role, from) -> {
            if (held.stream().anyMatch(from::contains)) {
                roles.add(role);
            }
        });
        return roles;
    }

    /** The caller's own roles. */
    public Set<String> of(Caller caller) {
        return of(caller.email(), caller.verified());
    }

    /**
     * The caller's roles: its own ({@link #of(Caller)}) and those it
     * {@link #shared shares} from {@code profile}'s owner.
     */
    public Set<String> of(Caller caller, Profiles.Profile profile) {
        var roles = new TreeSet<>(of(caller));
        roles.addAll(shared(caller, profile));
        return roles;
    }

    /**
     * The roles the caller gets from {@code profile}'s owner (null when
     * none): {@link #USER} when its account is linked to the profile, owned
     * by another account that is a member: one person, whichever of their
     * accounts signs in, uses the app; and {@link #PREMIUM} when the owner
     * has it, as the profile's cloud folder is the owner's. Empty for the
     * owner itself. Administration ({@link #ADMIN}, {@link #ROOT}) is never
     * shared: each account gets it only from its own email.
     */
    public Set<String> shared(Caller caller, Profiles.Profile profile) {
        var roles = new TreeSet<String>();
        if (profile == null || !caller.verified() || profile.ownerEmail() == null
                || profile.ownerSubject() != null && profile.ownerSubject().equals(caller.subject())) {
            return roles;
        }
        // The owner's email was verified when stored (Profiles keeps no other).
        var owner = of(profile.ownerEmail(), true);
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
        }
        return roles;
    }
}
