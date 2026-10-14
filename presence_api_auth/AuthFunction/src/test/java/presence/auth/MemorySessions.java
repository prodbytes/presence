package presence.auth;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/** {@link Sessions.Store} and {@link Identities} in memory, with DynamoDB's conditions. */
final class MemorySessions implements Sessions.Store, Identities {

    final Map<String, Sessions.Token> tokens = new HashMap<>();
    final Map<String, Sessions.Family> families = new HashMap<>();
    final Map<String, Identities.Identity> identities = new HashMap<>();

    @Override
    public synchronized void start(Sessions.Family family, String tokenHash, Sessions.Token token) {
        if (families.containsKey(family.id()) || tokens.containsKey(tokenHash)) {
            throw new IllegalStateException("exists");
        }
        families.put(family.id(), family);
        tokens.put(tokenHash, token);
    }

    @Override
    public synchronized Optional<Sessions.Token> token(String hash) {
        return Optional.ofNullable(tokens.get(hash));
    }

    @Override
    public synchronized Optional<Sessions.Family> family(String id) {
        return Optional.ofNullable(families.get(id));
    }

    @Override
    public synchronized boolean rotate(String oldHash, String nextHash, Sessions.Token next, Instant until,
                                       Instant now, Instant usedAfter) {
        var old = tokens.get(oldHash);
        var family = families.get(next.family());
        if (old == null || old.used() && !old.usedAt().isAfter(usedAfter) || tokens.containsKey(nextHash)
                || family == null || family.revoked()) {
            return false;
        }
        tokens.put(oldHash, new Sessions.Token(old.family(), old.who(), old.used() ? old.usedAt() : now,
                old.expiresAt()));
        tokens.put(nextHash, next);
        families.put(family.id(), new Sessions.Family(family.id(), family.subject(), false, until));
        return true;
    }

    @Override
    public synchronized void revoke(String id) {
        var family = families.get(id);
        if (family != null) {
            families.put(id, new Sessions.Family(id, family.subject(), true, family.expiresAt()));
        }
    }

    @Override
    public synchronized List<String> families(String subject) {
        var found = new ArrayList<String>();
        families.values().stream().filter(f -> f.subject().equals(subject)).forEach(f -> found.add(f.id()));
        return found;
    }

    @Override
    public synchronized Optional<Identities.Identity> get(String subject) {
        return Optional.ofNullable(identities.get(subject));
    }

    @Override
    public synchronized void saveName(String subject, String name, Instant at) {
        var was = identities.get(subject);
        identities.put(subject, new Identities.Identity(subject, name, was == null ? null : was.appleClientId(),
                was == null ? null : was.appleRefreshToken()));
    }

    @Override
    public synchronized void saveAppleToken(String subject, String clientId, String encrypted, Instant at) {
        var was = identities.get(subject);
        identities.put(subject, new Identities.Identity(subject, was == null ? null : was.name(), clientId,
                encrypted));
    }

    @Override
    public synchronized void clearAppleToken(String subject) {
        var was = identities.get(subject);
        if (was != null) {
            identities.put(subject, new Identities.Identity(subject, was.name(), null, null));
        }
    }

    @Override
    public synchronized void delete(String subject) {
        identities.remove(subject);
    }
}
