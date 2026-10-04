# Profiles

> **Data belongs to a profile, not to a login.** A profile is the stable
> owner of a user's data. The ways its owner signs in (a Google account
> today, other providers or emails later, and collaborators) are
> **subjects linked to the profile**. People can then change their email,
> switch or add authentication providers, or add collaborators **without
> losing their data**, because none of it is keyed by the email or the
> provider's account. Everything a user owns should be scoped to their
> profile.

## The rule

- **Every sign-in loads a profile.** When an authenticated user calls
  `GET /api/auth`, the [auth API](auth-api.md) looks up the profile linked
  to the token's **subject** and answers with it.
- **A first sign-in creates one.** If no profile is linked to the subject,
  a new profile is created and the subject is linked to it, so it is the
  user's current profile and **the next sign-in finds the same one**.
- **A subject is the issuer and the `sub`**, `<iss>#<sub>`, e.g.
  `https://accounts.google.com#1234567890`: the provider's stable account
  ID, never the email. The same account with a new email keeps its
  profile; another account with the old email gets its own. The same `sub`
  from another issuer is another subject.
- **Many subjects, one profile.** The links table maps each subject to one
  profile, and any number of subjects may point at the same profile. This
  is what lets more providers, emails or collaborators be added later.
- **Everyone signed in has a profile,** whatever their roles: a user
  without `presence_user` (see [Membership](membership.md)) has one too,
  so nothing is lost when access is granted later.
- **Nobody signed in has none:** the anonymous route
  (`GET /api/auth/anonymous`) and [DEV mode](execution-mode.md) don't
  create or return profiles.

## Profile IDs

- Like [device IDs](devices-users-places.md#devices), a profile ID is
  two different adjectives and an **animal**, lowercase, joined by
  **underscores**: `automatic_paranoid_axolotl` (`ProfileId`), the same
  shape as a device ID (`automatic_paranoid_gadget`). The two are
  separate namespaces: 191 animals are also device "things", so a profile
  and a device can have the same ID string. Where both show, as in
  Settings, a label says which is which.
- The words: the device ID's **1053 adjectives** and **1031 animals**
  (`presence_api_auth/AuthFunction/src/main/resources/presence/auth/`
  `adjectives.txt`, `animals.txt`), a-z only, each unique, with words that
  read as insults left out. That's about **1.14 billion** IDs, picked with
  a secure random generator.
- **No two profiles ever share an ID.** A long list makes a repeat
  unlikely (about 1% odds among 5,000 profiles), and the profiles table
  makes it impossible: a new profile is written only if its ID isn't
  taken (a conditional put), and a taken ID is replaced by a fresh one, up
  to 10 tries, before the sign-in fails.

## Where it's kept

Two DynamoDB tables in the auth API's stack (on-demand, encrypted, with
point-in-time recovery, kept if the stack is deleted; contents only in
AWS):

| Table | Key | Attributes |
|---|---|---|
| `ProfilesTable` | `id` (the profile ID) | `createdAt`, `lastSignInAt` (epoch ms) |
| `ProfileSubjectsTable` | `subject` (`<iss>#<sub>`) | `profileId`, `email` (lowercase, at link time), `linkedAt` (epoch ms) |

- **Finding:** a consistent read of the subject's link. A found profile's
  `lastSignInAt` is updated (and the profile row recreated if a link names
  one that's missing).
- **Creating:** the new profile is put first (only if its ID is free),
  then the link (only if the subject has none). If two first sign-ins of
  the same subject race, the first link wins and the other sign-in reads
  it, so both get the same profile; the loser's new profile is left
  unused.
- **Least privilege:** the roles function (`AuthFunction`) may get and put
  links, and put and update profiles; nothing else touches the tables.

## In the API and the app

- `GET /api/auth` answers `{"email": "...", "profile":
  "automatic_paranoid_axolotl", "roles": [...]}`; `profile` is `null` only
  for a token without an issuer or subject.
- The app reads it into `RolesService.profile`
  ([lib/auth/roles_service.dart](../presence_app/lib/auth/roles_service.dart)),
  set with the roles at each check and cleared while signed out, checking,
  in DEV, or after a failed check.
- **Settings always shows it**, as **Profile** `huge_wavy_darter` under
  the device ID, or why there's none (*none in DEV*, *checking…*, *not
  signed in*, *unavailable*); see [Settings screen](settings.md).

## Not scoped to the profile yet

The profile exists and is loaded at every sign-in, but the data isn't
moved onto it yet. These still use the login, and are the next steps:

- **Events** carry the Google account ID as `userId` (see [Devices, users
  and places](devices-users-places.md#users)), not the profile ID.
- **Cloud sync** stores everything under the user's Cognito identity ID,
  which Cognito derives from the Google account (see [Cloud
  sync](cloud-sync.md)). A new provider would get a new identity and an
  empty folder.
- **Roles** are still declared per email in `UserRolesTable`, and
  membership requests are per email (see [Membership](membership.md)).
- There's no way yet to **link another subject** to a profile (a second
  provider, a new email, a collaborator).

## Verified

- `ProfilesTest` (JUnit): a first sign-in creates a profile and the next
  finds it; the subject, not the email, finds it; a second subject linked
  to a profile shares it; a race keeps the first link; a link whose
  profile is missing gets it back; taken IDs are skipped and never
  overwritten, and the sign-in fails after 10; IDs are two different
  adjectives and an animal, from over a billion, with 1000+ unique a-z
  words in each list; no subject, no profile; the handler answers with the
  profile, also for users without roles, and the anonymous route makes
  none.
- `roles_test.dart`: `HttpRolesClient` reads `profile` (absent or null is
  null), and `RolesService.profile` follows sign-in, failures and
  sign-out.
- `add_device_test.dart`: Settings shows the device ID, then the profile
  ID; *unavailable* without one, *none in DEV* in DEV, and *loading…*
  before the device ID is known.
- Locally, against Floci's DynamoDB: the deployed `AuthFunction`, called
  with a signed-in event, creates a profile and link, and returns the same
  profile on the next call.

## Known limitations

- Any Google account can create a profile by signing in (one per
  subject; `GET /api/auth` is throttled to 20 requests/s, burst 50).
- A lost race leaves one unused profile row.
- Profiles are never deleted.
