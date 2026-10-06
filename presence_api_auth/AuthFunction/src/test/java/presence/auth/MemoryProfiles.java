package presence.auth;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** The profiles and subject links tables, in memory. */
class MemoryProfiles implements Profiles.Store {

    /** subject -> profile ID. */
    final Map<String, String> links = new HashMap<>();

    /** subject -> its email, as linked. */
    final Map<String, String> emails = new HashMap<>();

    /** profile ID -> its last sign-in. */
    final Map<String, Instant> profiles = new HashMap<>();

    /** profile ID -> the profile's owner and identity. */
    final Map<String, Profiles.Profile> details = new HashMap<>();

    @Override
    public boolean create(String id, String ownerSubject, String ownerEmail, String ownerHd, Instant now) {
        if (profiles.putIfAbsent(id, now) != null) {
            return false;
        }
        details.put(id, new Profiles.Profile(id, "", ownerSubject, ownerEmail, ownerHd));
        return true;
    }

    @Override
    public Profiles.Profile profile(String id) {
        return profiles.containsKey(id) ? details.getOrDefault(id, new Profiles.Profile(id, "", "", null, null)) : null;
    }

    @Override
    public String linked(String subject) {
        return links.get(subject);
    }

    @Override
    public boolean link(String subject, String profileId, String email, Instant now) {
        if (links.putIfAbsent(subject, profileId) != null) {
            return false;
        }
        emails.put(subject, email == null ? "" : email);
        return true;
    }

    @Override
    public void relink(String subject, String profileId, String email, Instant now) {
        links.put(subject, profileId);
        emails.put(subject, email == null ? "" : email);
    }

    @Override
    public void unlink(String subject) {
        links.remove(subject);
        emails.remove(subject);
    }

    @Override
    public List<Profiles.Member> members(String profileId) {
        var result = new ArrayList<Profiles.Member>();
        links.forEach((subject, id) -> {
            if (id.equals(profileId)) {
                result.add(new Profiles.Member(subject, id, emails.getOrDefault(subject, "")));
            }
        });
        return result;
    }

    @Override
    public Profiles.Profile signedIn(String profileId, Instant now) {
        profiles.put(profileId, now);
        return profile(profileId);
    }

    @Override
    public void owner(String profileId, String email, String hd) {
        var p = profile(profileId);
        details.put(profileId, new Profiles.Profile(profileId, p.identityId(), p.ownerSubject(), email, hd));
    }

    @Override
    public Profiles.Profile identity(String profileId, String identityId) {
        var p = profile(profileId);
        if (p != null && !p.hasIdentity()) {
            details.put(profileId, new Profiles.Profile(profileId, identityId, p.ownerSubject(), p.ownerEmail(), p.ownerHd()));
        }
        return profile(profileId);
    }
}
