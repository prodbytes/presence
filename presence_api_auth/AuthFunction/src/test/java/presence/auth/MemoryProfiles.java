package presence.auth;

import java.time.Instant;
import java.util.HashMap;
import java.util.Map;

/** The profiles and subject links tables, in memory. */
class MemoryProfiles implements Profiles.Store {

    /** subject -> profile ID. */
    final Map<String, String> links = new HashMap<>();

    /** profile ID -> its last sign-in. */
    final Map<String, Instant> profiles = new HashMap<>();

    @Override
    public boolean create(String id, Instant now) {
        return profiles.putIfAbsent(id, now) == null;
    }

    @Override
    public String linked(String subject) {
        return links.get(subject);
    }

    @Override
    public boolean link(String subject, String profileId, String email, Instant now) {
        return links.putIfAbsent(subject, profileId) == null;
    }

    @Override
    public void signedIn(String profileId, Instant now) {
        profiles.put(profileId, now);
    }
}
