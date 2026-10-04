# Profiles

A **profile** is one person: one folder in the user-data bucket and every
Google account that signs in to it. Someone with two Google accounts, such
as `julio@gmail.com` and `julio@nu01.com`, links them and reaches the same
clips, events and settings, with the same roles, from either one. The
accounts can be from the same provider (two Google accounts), which a
Cognito identity pool can't link on its own: an identity holds one login
per provider.

## How it works

- The [auth API](auth-api.md) keeps the mapping: the **accounts table**
  has one item per Google account, keyed by its Google `sub` (which never
  changes, unlike the email), with its profile ID, the profile's Cognito
  identity ID, the owner's email and whether it's the owner.
- **Credentials** (`POST /api/auth/credentials`, `presence_user` only):
  the API looks up the account's profile and calls Cognito's
  `GetOpenIdTokenForDeveloperIdentity` for it (developer provider
  `login.presence.profiles`, the profile ID as the user identifier). The
  app trades that token for AWS credentials
  (`GetCredentialsForIdentity`). Every linked account gets the same
  identity, so the same folder. The bucket policy is unchanged:
  `<bucket>/${cognito-identity.amazonaws.com:sub}/*`. See
  [Cloud sync](cloud-sync.md#how).
- **A new account** gets a profile of its own the first time it asks for
  credentials or a link code. That profile uses the identity the account's
  Google sign-in already had (`GetId` with its Google token). So data
  uploaded before profiles stays where it is, and nothing moves.
- **Roles:** a linked account has its own roles plus the owner's (the
  account that made the profile). This applies in `GET /api/auth`, the
  Admin routes and the profile routes. A `julio@gmail.com` linked to a
  `julio@nu01.com` profile is a `presence_user` and `presence_admin`, like
  the owner.

## Linking

1. Signed in with an account that has access, open the account sheet's
   **Linked accounts** and tap **Link another account**. A code such as
   `K7QF-M2XD` shows. It works once, for **10 minutes**.
2. Sign out, sign in with the other Google account, and open **Linked
   accounts** (from the account sheet, or from the sign-up sheet's "Have
   access with another Google account? Link it" if that account has no
   access yet). Enter the code and tap **Link this account**.
3. That account joins the profile: the sheet lists both accounts, the
   roles are checked again, and cloud sync starts over on the profile's
   folder. Events stored on the device upload there.

- **Codes:** 8 characters from 32 that don't look alike (no I, O, 0 or 1),
  so 40 bits. Typed in any case, with or without the dash. They're stored
  only as their SHA-256, deleted when used, and expire by DynamoDB TTL
  (and are checked on use, since TTL deletion lags). Both code routes are
  throttled to 1 request a second (burst 5).
- **Refused (409):**
  - the account has cloud data of its own: its own profile's folder (or,
    before it has a profile, its Google identity's folder) isn't empty.
    Linking it would strand that data;
  - the account owns a profile that other accounts are linked to.
  An account already linked to another profile (not its owner) can move.
- A wrong, used or expired code answers 404, and the sheet says so.

## Unlinking

- The **Linked accounts** sheet lists the profile's accounts (the owner
  first, marked **Owner**, and **This account**). Every account but the
  owner has an **Unlink** button, available to any member.
- An unlinked account loses the owner's roles. Its next sign-in gives it a
  profile of its own again, on its own Google identity.

## Routes

| Route | Who | Answer |
|---|---|---|
| `POST /api/auth/credentials` | `presence_user` | `{"identityId", "token"}` |
| `GET /api/auth/profile` | any verified account | `{"accounts": [{email, owner, current}]}` (just the caller before it has a profile) |
| `POST /api/auth/profile/link-code` | `presence_user` | 201 `{"code": "ABCD-EFGH", "expiresAt"}` |
| `POST /api/auth/profile/link` | any verified account (body: the code) | the accounts, or 404 / 409 |
| `POST /api/auth/profile/unlink` | a member (body: the email) | the accounts, or 404, or 409 for the owner |

- Every route needs a verified email. A Cognito or DynamoDB failure
  answers 502 without its details. Without an identity pool and bucket
  (locally, by default) every route but the listing answers 503.

## Infrastructure

- **Identity pool** ([presence_infra/identity.yaml](../presence_infra/identity.yaml)):
  `DeveloperProviderName: login.presence.profiles`, which can't be changed
  once set. Google stays as a login provider, because the API's `GetId`
  needs it to find an account's identity from before profiles.
- **Auth API** ([presence_api_auth/template.yaml](../presence_api_auth/template.yaml)):
  - `AccountsTable` (key `sub`, index `profile` by `profileId`; on-demand,
    encrypted, point-in-time recovery, kept if the stack is deleted);
  - `LinkCodesTable` (key: the code's hash, TTL `expiresAt`);
  - `ProfileFunction` (`ProfileHandler`), which may:
    - get, put, delete and query the accounts table;
    - put and delete link codes;
    - call `GetId` and `GetOpenIdTokenForDeveloperIdentity` on this pool
      only;
    - call `s3:ListBucket` on the user-data bucket, only to see whether a
      folder is empty.
  - The roles and admin functions may also read the accounts table, for
    the owner's roles.
- Locally, Floci gets the same routes
  ([05-auth-api.sh](../presence_floci/init/ready.d/05-auth-api.sh)).

## In the app

- `CognitoCredentials` ([lib/cloud/cognito.dart](../presence_app/lib/cloud/cognito.dart))
  asks `POST /api/auth/credentials` (`ApiConfig.baseUrl`), then
  `GetCredentialsForIdentity` with
  `Logins: {"cognito-identity.amazonaws.com": <token>}`. A 401 from the
  API is shown as "Sign in again to resume uploads", like an expired
  Google token.
- `ProfileClient` ([lib/auth/profile_client.dart](../presence_app/lib/auth/profile_client.dart))
  and `LinkedAccountsSheet` ([lib/auth/linked_accounts_sheet.dart](../presence_app/lib/auth/linked_accounts_sheet.dart)).
  After a link or unlink, `RolesService.refresh()` checks the roles again
  and `CloudSync.reconnect()` drops the credentials and starts over, as for
  a new user.

## Verified

- JUnit (`ProfileTest`, 14 tests):
  - an existing user keeps the identity Google sign-in gave them;
  - credentials need `presence_user`;
  - a linked account gets the same identity and the owner's roles (also
    in `GET /api/auth`);
  - codes are single-use, expire, are well-formed, and are stored only as
    hashes;
  - only members make codes;
  - an account with its own data isn't linked;
  - a profile with linked accounts can't join another, but a linked
    account can move;
  - unlinking: never the owner, and unknown emails get 404;
  - the listing before a profile exists;
  - 503 without cloud sync, and unverified emails are refused.
- Flutter (`profile_test.dart`):
  - the credentials exchange (the API, then Cognito, with the developer
    token), reused while valid, and 401 versus 403;
  - `reconnect` uploads under the new folder and lists all events again;
  - an account without access links with a code and gains access;
  - a member makes a code and unlinks an account;
  - a refused link says why.
- Floci: the stack deploys with both tables and the function's five
  routes.
- Not yet run against AWS: the identity pool update and the Cognito calls.

## Known limitations

- **No merge:** an account with cloud data of its own can't be linked.
  Its data expires with the bucket's 90 days, or it can stay unlinked.
- The owner's email is copied onto each linked account when it links. If
  the owner's Google email changes, linked accounts keep the old one for
  roles until they link again.
- Cloud sync still uploads only events whose `userId` is the signed-in
  account's Google ID (see [Devices, users and
  places](devices-users-places.md)). Events another linked account
  recorded on the same device don't go up from this account, though they
  usually already have from theirs.
- Google stays a login provider of the pool, so an account can still get
  credentials straight from Cognito for its own Google identity's folder,
  without the roles check, as before profiles. Removing it would also
  remove `GetId`, which finds pre-profile data. Remove it once every
  existing account has a profile.
