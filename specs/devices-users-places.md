# Devices, users and places

Three things events belong to. Every event records the **device** it was
recorded on and the **user** it belongs to. Above the user is the
signed-in user's [profile](profiles.md), the intended owner of all their
data; events don't carry it yet. **Places** are defined here but
not built yet.

## Devices

- A **device** is one install of the app: a browser profile on web, or the
  app on a phone. Its cameras are its own (camera IDs are a separate thing;
  see [Storage](storage.md)).
- **The device ID** is made on the device's first launch and kept from then
  on: two different adjectives and a thing, lowercase, joined by
  underscores, such as `automatic_paranoid_gadget`
  ([lib/identity/device_id.dart](../presence_app/lib/identity/device_id.dart)).
  - The words are picked with a secure random generator from 1053
    adjectives and 1091 things
    ([device_words.dart](../presence_app/lib/identity/device_words.dart)),
    about 1.2 billion IDs. Two of 5,000 devices share an ID with about 1%
    odds, and two of 50,000 with about 64%. Words that read as insults,
    and weapons, were left out.
  - It's saved in the `settings` store under `device` (`{"id": …}`), read
    and created in one transaction, so two tabs opening at once agree. On
    web, clearing the site's data makes a new device.
- **Consent:** right after the ID is known, the device must have a
  [recording consent](consent.md), asked once, before anything shows or
  records.
- **Its operating system** is recorded on every event it publishes
  (`os`; see [Events](events.md)), so the account sheet's device list can
  show each device's OS, with its icon, and its latest event (see
  [Sign-in](sign-in.md)).
- **Settings always shows it**, small and selectable, under the version
  and above the profile ID (see
  [Settings screen](settings.md)), above the Location section with where
  the device is (see [Device location and battery](device-location.md)).
- **Adding a device:** Settings' **Add a device** shows a QR code and a
  link that open Presence on another device. That device keeps its own
  device ID (the link's is the sharing device's, never copied) and, after a
  sign-in checked against the link, is one more device of the same user. See
  [Add a device](add-device.md).

## Users

- A **user** is a signed-in Google account. Its ID is the account's stable
  Google ID (`AuthUser.id`, the token's `sub`), not the email.
- **Events belong to a [profile](profiles.md)**, not to a user or a
  device: `profileId` (e.g. `automatic_paranoid_axolotl`), the profile
  the auth API answered the signed-in account with (`RolesService.profile`).
  So the same account on two devices, or two accounts linked to one
  profile, share their events. `userId` still records who was signed in.
- **No sign-in, no profile.** While nobody is signed in (or before the API
  answers a sign-in), events are saved with no profile, and with the user
  `anonymous` (`AppEvent.anonymousUserId`) when nobody is signed in. They
  stay on the device: nothing syncs without a profile. That's everything
  in [DEV](execution-mode.md), where nobody signs in.
- **At sign-in, the device's events get the profile.** Once the API
  answers a sign-in (or a session restored at launch) with the profile,
  every event on the device without a profile becomes the profile's
  (`Persistence.claimForProfile`), and anonymous ones the user's. Nothing
  is lost: three clips grabbed signed out plus two after signing in are
  five events of the profile's, in the timeline and in the cloud.
  - Taken: events without a profile recorded signed out, by this user
    before the API answered, or by this user before events had profiles.
  - Not taken: another profile's events, and another user's from before
    events had profiles.
  - It runs after the history is restored and pending saves are done, then
    updates the events in memory (so later saves, such as a clip
    completing or a tag, keep the profile) and the stored records.
  - After a sign-out the profile's events stay its; new ones have none
    until the next sign-in.
- **Cloud sync uploads only the profile's events**, and the clips those
  events show (see [Cloud sync](cloud-sync.md)). Events fetched from the
  profile's folder are its.

## Places

- A **place** is a group of devices, such as "Home" with the front door and
  garage phones. Not built yet: there's no place ID on events and no way to
  make or join a place.

## On every event

| Field | Value |
|---|---|
| `deviceId` | the recording device's ID, set when the event is saved |
| `userId` | the signed-in user's Google ID when it's saved, or `anonymous` until a user signs in |
| `profileId` | the profile it belongs to: the signed-in account's when it's saved, or absent until a sign-in gives it one |
| `location` | where the device was when it was published (`lat`, `lng`, `accuracy`, `source`, `time`; see [Device location](device-location.md)), or absent while unknown |

All four are in the stored record, in the cloud JSON, and on `AppEvent`
([lib/events.dart](../presence_app/lib/events.dart)).

## Verified

- `device_id_test.dart`: the format, two different adjectives, words that
  are unique and a-z only, over a billion IDs, and 5,000 generated IDs with
  at most a few repeats.
- `persistence_test.dart`: three events signed out, a sign-in, two more:
  all five, and the sign-in and start events, upload with the user's ID,
  the profile and the same device ID, and so are stored and in the
  timeline. After a sign-out, new events have no profile and don't upload
  until the next sign-in gives them one. Another profile's and another
  user's events aren't taken. Settings shows the device ID, the same
  after a refresh.
- `cloud_sync_test.dart`: events without the profile, and another user's
  clip, aren't uploaded; nothing syncs until the API answers with a
  profile; fetched events get the profile.

## Known limitations

- The timeline still shows every event stored on the device, whatever its
  profile: a second user signing in on a shared device sees the first
  user's history (but doesn't sync it).
- Events recorded signed out are taken by whoever signs in next on the
  device, even if someone else recorded them.
- Clips and cameras have no device or user ID of their own; they follow
  their event.
