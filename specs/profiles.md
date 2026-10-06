# Profiles

> **Data belongs to a profile, not to a login.** A profile is the stable
> owner of a user's data: one folder in the user-data bucket, and roles.
> The ways its owner signs in are **subjects linked to the profile**. That
> can be one Google account or several, even two from Google (for example
> `julio@gmail.com` and `julio@nu01.com`), and other providers later.
> People can change their email, add accounts or switch providers
> **without losing their data**, because none of it is keyed by the email
> or the provider's account.

## The rule

- **No sign-in, no profile.** While nobody is signed in (and in
  [DEV](execution-mode.md), where nobody can), the app has no profile
  (`null`). Events recorded then have none, and nothing syncs.
- **A sign-in finds the account's profile, or makes one.** The app asks
  `GET /api/auth`. If the token's **subject** is linked to a profile, the
  [auth API](auth-api.md) answers with it. If not, it creates a profile
  with a fresh ID, owned by the subject, and links it, so **every later
  sign-in finds the same one**.
- **Same account, same profile, on every device.** The profile is found
  by the subject, never by the device, so signing in with one account on a
  phone and a laptop gives both the same profile, the same folder and the
  same events.
- **At sign-in, the device's events get the profile.** Everything recorded
  here without a profile (signed out, while the sign-in was being
  answered, or before events had profiles) becomes the profile's, and
  syncs. See [Devices, users and places](devices-users-places.md#users).
- **A subject is the issuer and the `sub`**, `<iss>#<sub>`, e.g.
  `https://accounts.google.com#1234567890`. That's the provider's stable
  account ID, never the email. The same account with a new email keeps its
  profile; another account with the old email gets its own. The same `sub`
  from another issuer is another subject.
- **Many subjects, one profile.** The links table maps each subject to one
  profile, and any number of subjects may point at the same profile. A
  subject joins another profile with a **link code** (below). A Cognito
  identity pool can't link accounts itself, since an identity holds only
  one login per provider, which is why the auth API keeps the links.
- **Everyone signed in has a profile,** whatever their roles. A user
  without `presence_user` (see [Membership](membership.md)) has one too.
- The anonymous route (`GET /api/auth/anonymous`) never creates or
  returns profiles, so nobody can make profile rows without signing in.

## Profile IDs

- Like [device IDs](devices-users-places.md#devices), a profile ID is two
  different adjectives and an **animal**, lowercase, joined by
  **underscores**: `automatic_paranoid_axolotl` (`ProfileId`), the same
  shape as a device ID (`automatic_paranoid_gadget`).
  - The two are separate namespaces: 191 animals are also device
    "things", so a profile and a device can have the same ID string.
  - Where both show, as in Settings, a label says which is which.
- The words:
  - the device ID's **1053 adjectives** and **1031 animals**
    (`presence_api_auth/AuthFunction/src/main/resources/presence/auth/`
    `adjectives.txt`, `animals.txt`), a-z only, each unique;
  - words that read as insults are left out;
  - that's about **1.14 billion** IDs, picked with a secure random
    generator.
- **No two profiles ever share an ID.**
  - A long list makes a repeat unlikely: about 1% odds among 5,000
    profiles.
  - The profiles table makes it impossible: a new profile is written only
    if its ID isn't taken (a conditional put).
  - A taken ID is replaced by a fresh one, up to 10 tries, before the
    sign-in fails.
- **Only the auth API makes profile IDs.** The app no longer makes one or
  sends one. The API still accepts `?profile=<id>` and uses it for a new
  profile if it's valid (`ProfileId.valid`) and free, but the app doesn't
  send it.
- The profile ID is also the user identifier Cognito knows the profile by
  (its developer identity).

## The profile's folder and roles

- **Credentials** (`POST /api/auth/credentials`, `presence_user` only):
  - the API calls Cognito's `GetOpenIdTokenForDeveloperIdentity` for the
    profile's identity (developer provider `login.presence.profiles`, the
    profile ID as the user identifier);
  - the app trades that token for AWS credentials
    (`GetCredentialsForIdentity`; see [Cloud sync](cloud-sync.md#how));
  - the API also attaches the live-sync IoT policy to the identity
    (`iot:AttachPolicy`, idempotent; a failure is logged and doesn't fail
    the call), so its devices can use [live sync](live-sync.md) on their
    profile's own MQTT topics;
  - every subject of the profile gets the same identity, so the same
    folder;
  - the bucket policy is unchanged:
    `<bucket>/${cognito-identity.amazonaws.com:sub}/*`.
- **The identity is set once**, at the profile's first credentials or link
  code. It's the identity the caller's Google sign-in already had (`GetId`
  with its Google token), so data uploaded before profiles stays where it
  is and nothing moves. After that the folder never changes (a conditional
  write).
- **Linking the profile ID to the identity:** that identity was made by
  Google sign-in, and Cognito adds another login to an identity only
  beside one it already has; the profile ID alone answers
  `NotAuthorizedException: Logins don't match`. So the API asks with the
  profile ID alone and, when Cognito refuses, again with the caller's
  Google ID token beside it (`accounts.google.com`), which links the
  profile ID for good. After that the profile ID alone works, for every
  account in the profile. A link code links it too, so accounts that join
  (whose Google logins aren't on the identity) get credentials.
- **Roles:** a subject has its own roles plus the **owner's**, the subject
  that made the profile. This applies in `GET /api/auth`, the Admin routes
  and the profile routes. The owner's email is kept on the profile and
  updated when the owner signs in with a new one. A `julio@gmail.com`
  linked to a `julio@nu01.com` profile is a `presence_user`,
  `presence_admin` and `presence_root`, like the owner.

## Linking

1. Signed in with an account that has access, open the account sheet's
   **Linked accounts** and tap **Link another account**. A code such as
   `K7QF-M2XD` shows. It works once, for **10 minutes**.
2. Sign out, sign in with the other account, and open **Linked accounts**.
   It's in the account sheet, or, for an account without access yet, in
   the sign-up sheet ("Have access with another Google account? Link it").
   Enter the code and tap **Link this account**.
3. That subject joins the profile:
   - the sheet lists both accounts;
   - the roles are checked again, and Settings shows the new profile ID;
   - cloud sync starts over on the profile's folder.

- **Codes:**
  - 8 characters from 32 that don't look alike (no I, O, 0 or 1), so 40
    bits; typed in any case, with or without the dash;
  - stored only as their SHA-256, deleted when used;
  - they expire by DynamoDB TTL, and are checked on use, since TTL
    deletion lags;
  - both code routes are throttled to 1 request a second (burst 5).
- **Refused (409)** when the joining subject owns its profile and:
  - that profile has cloud data: its folder (or, before it has one, its
    Google identity's folder) isn't empty. Linking would strand the data;
  - other subjects are linked to it.

  A subject linked to another profile (not its owner) can move. A wrong,
  used or expired code answers 404, before anything is made for the
  caller.

## Unlinking

- **Linked accounts** lists the profile's subjects: the owner first,
  marked **Owner**, then **This account**. Every account but the owner has
  an **Unlink** button, available to any member.
- An unlinked subject loses the owner's roles. Its next sign-in gives it a
  new profile of its own, whose folder is its own Google identity's.

## Routes

| Route | Who | Answer |
|---|---|---|
| `GET /api/auth` | any signed-in user | `{"email", "profile", "roles"}` (the subject's profile, made at its first sign-in) |
| `POST /api/auth/credentials` | `presence_user` | `{"identityId", "token"}` |
| `GET /api/auth/profile` | any verified account | `{"profile", "accounts": [{email, owner, current}]}` |
| `POST /api/auth/profile/link-code` | `presence_user` | 201 `{"code": "ABCD-EFGH", "expiresAt"}` |
| `POST /api/auth/profile/link` | any verified account (body: the code) | the listing, or 404 / 409 |
| `POST /api/auth/profile/unlink` | a member (body: the email) | the listing, or 404, or 409 for the owner |

- `profile` is `null` only for a token without an issuer or subject.
- The profile routes need a verified email. A Cognito or DynamoDB failure
  answers 502 `{"error": "the profile service failed", "cause",
  "requestId"}`: `cause` is the AWS service, the operation that failed
  (the SDK client's method in the stack trace, when it's there), error
  code and HTTP status (`CognitoIdentity GetId: AccessDeniedException
  (HTTP 400)`), or the exception's type for other failures. An
  `UnknownOperationException`, which AWS itself never answers to the SDK,
  adds "the endpoint doesn't implement it (a local AWS emulator?)".
  `requestId` is the Lambda request ID, which finds the full error in the
  function's log (`presence: <route> failed (request <id>): <cause>:
  <exception>`). AWS's message, which names ARNs, isn't sent. Without an
  identity pool and bucket (locally, by default), every profile route but
  the listing answers 503.

## Where it's kept

DynamoDB tables in the auth API's stack. They're on-demand and encrypted,
the first two have point-in-time recovery and are kept if the stack is
deleted, and the contents live only in AWS.

| Table | Key | Attributes |
|---|---|---|
| `ProfilesTable` | `id` (the profile ID) | `createdAt`, `lastSignInAt` (epoch ms), `ownerSubject`, `ownerEmail`, `identityId` |
| `ProfileSubjectsTable` | `subject` (`<iss>#<sub>`); index `profile` by `profileId` | `profileId`, `email` (lowercase), `linkedAt` (epoch ms) |
| `LinkCodesTable` | `code` (its SHA-256) | `profileId`, `createdBy`, `expiresAt` (epoch s, TTL) |

- **Finding:** a consistent read of the subject's link. A found profile's
  `lastSignInAt` is updated, which also returns the profile, and the
  profile row is recreated if a link names one that's missing.
- **Creating:** the new profile is put first, only if its ID is free.
  Then comes the link, only if the subject has none. If two first sign-ins
  of the same subject race, the first link wins and the other sign-in
  reads it, so both get the same profile. The loser's new profile is left
  unused.
- **Least privilege:**
  - the roles function (`AuthFunction`) may get and put links, and get,
    put and update profiles;
  - the admin function may only get both, to find the owner's roles;
  - the profile function (`ProfileFunction`) may get, put, delete and
    query links, get, put and update profiles, and put and delete link
    codes;
  - it may also call `GetId` and `GetOpenIdTokenForDeveloperIdentity` on
    this pool only, and `s3:ListBucket` on the user-data bucket, only to
    see whether a folder is empty.
- **Identity pool** ([presence_infra/identity.yaml](../presence_infra/identity.yaml)):
  `DeveloperProviderName: login.presence.profiles`, which can't be changed
  once set. Adding it to an existing pool keeps the pool and its identity
  IDs ("update requires: no interruption"). Google stays as a login
  provider, because the API's `GetId` needs it to find an account's
  pre-profile identity.
- Locally, Floci gets the same routes
  ([05-auth-api.sh](../presence_floci/init/ready.d/05-auth-api.sh)).

## In the app

- `RolesService.profile`
  ([lib/auth/roles_service.dart](../presence_app/lib/auth/roles_service.dart))
  is the profile the auth API answered the signed-in account with. It's
  null signed out, in DEV, and from a sign-in until the API answers.
  Another account drops the last one's at once. A failed check of the same
  account keeps it. It isn't stored: each launch asks the API again.
- **Events:** every event saved while there's a profile gets it
  (`AppEvent.profileId`). When the profile arrives, the events without one
  become its (`Persistence.claimForProfile`); see [Devices, users and
  places](devices-users-places.md#users).
- **Settings shows it**, as **Profile** `huge_wavy_darter` under the
  device ID, or *none until signed in*; see [Settings screen](settings.md).
  The [account sheet](sign-in.md) shows it with the profile's devices.
- `CognitoCredentials` ([lib/cloud/cognito.dart](../presence_app/lib/cloud/cognito.dart))
  asks `POST /api/auth/credentials`, then `GetCredentialsForIdentity`.
  A 401 from the API shows as "Sign in again to resume uploads".
- `ProfileClient` ([lib/auth/profile_client.dart](../presence_app/lib/auth/profile_client.dart))
  and `LinkedAccountsSheet` ([lib/auth/linked_accounts_sheet.dart](../presence_app/lib/auth/linked_accounts_sheet.dart))
  handle linking. After a link or unlink, `RolesService.refresh()` checks
  again, and `CloudSync.reconnect()` drops the credentials and starts over,
  as for a new user.

## Verified

- `ProfilesTest` (JUnit, 11 tests):
  - a first sign-in creates a profile and the next finds it;
  - the subject, not the email, finds it, and a linked subject shares it;
  - a race keeps the first link;
  - a link whose profile is missing gets it back;
  - taken IDs are skipped, and the sign-in fails after 10;
  - a requested ID (`?profile=`, which the app no longer sends) is used
    when valid and free; a linked subject keeps its own whatever is sent;
  - the ID format and word lists;
  - no subject, no profile;
  - the handler answers with the profile, claims the app's
    (`?profile=`), and the anonymous route makes none.
- `ProfileTest` (JUnit, 15 tests):
  - an existing user keeps the identity Google sign-in gave them;
  - credentials need `presence_user`;
  - a linked subject gets the same identity and the owner's roles, also
    in `GET /api/auth` and the Admin lookup, which never makes a profile;
  - the owner's new email carries its roles;
  - codes are single-use, expire, are well-formed, and are stored only as
    hashes;
  - only members make codes;
  - a subject with its own data isn't linked;
  - a profile with linked subjects can't join another, but a linked
    subject can move;
  - unlinking never removes the owner, and an unlinked subject gets a new
    profile;
  - the listing, 503 without cloud sync, and unverified emails.
- Flutter:
  - `roles_test.dart`: no profile signed out or in DEV; a sign-in gets the
    account's (without access too), with nothing sent; two devices of the
    same account get the same one; a failed check keeps it, and another
    account drops it at once;
  - `add_device_test.dart`: Settings shows the profile, or *none until
    signed in*;
  - `persistence_test.dart`: events recorded signed out get the profile
    at sign-in and upload with it; after a sign-out new events have none
    and stay local until the next sign-in; another profile's or user's
    events aren't taken;
  - `cloud_sync_test.dart`: nothing syncs until the API answers with a
    profile; only its events go up; fetched events become its;
  - `profile_test.dart`:
    - the credentials exchange, reused while valid, and 401 versus 403;
    - `reconnect` switches folders;
    - linking with a code, making a code, unlinking, and a refused link.
- Floci: the stack deploys with the tables, the function and its routes.

## Known limitations

- **Not locally with Floci:** Floci (the local AWS) has no Cognito
  Identity: with an identity pool set in `.env`, `/api/auth/credentials`
  fails with `CognitoIdentity GetId: UnknownOperationException (HTTP 400);
  the endpoint doesn't implement it (a local AWS emulator?)`, so cloud
  sync doesn't work on the local stack. Production and RC call AWS.

- **No merge:** a subject whose own profile has cloud data can't be
  linked. Its data expires with the bucket's 90 days, or it can stay
  unlinked.
- Roles are still declared per email in `UserRolesTable`, and membership
  requests are per email. Linked subjects share the owner's roles.
- Google stays a login provider of the pool. An account can therefore
  still get credentials straight from Cognito for its own Google
  identity's folder, without the roles check, as before profiles. Remove
  it once every account has a profile with an identity.
- Events recorded signed out on a shared device go to whoever signs in
  next, not necessarily who recorded them.
- With the auth API unreachable at launch, a restored session has no
  profile until it answers: events recorded meanwhile wait, and get it
  then.
- Any Google account can create a profile by signing in (one per subject;
  `GET /api/auth` is throttled to 20 requests/s, burst 50). A lost race
  leaves one unused profile row. Profiles are never deleted.
- A linked subject's email in the links table is the one it had when it
  linked.
