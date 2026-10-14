# Account deletion

A signed-in user can **delete their account from inside the app**, on
every platform, and anyone can **ask for it without the app** on a public
page, https://presence.nu01.com/delete-account. This is what App Store
guideline 5.1.1(v) and Google Play's account deletion policy require (see
[Store readiness](store-readiness.md)).

What goes depends on the account's place in its [profile](profiles.md):

- **The profile's owner** (the account that made it) deletes the **whole
  profile**: its cloud data, its identity and every linked account's link.
- **A linked account** only **leaves the profile**: its link, and its own
  Feedback and Help messages. The profile and its data stay the owner's.

## In the app

- **Where:** the account sheet's last button, under **Sign out**: **Delete
  account** (`delete-account`, error-colored, `person_remove_outlined`;
  `DeleteAccountButton`,
  [lib/auth/delete_account.dart](../presence_app/lib/auth/delete_account.dart)).
  The sheet is the Profile tab's page, or the bottom sheet from the app
  bar's account button (signed in without access too). It shows only once
  the auth API has answered with the account's profile (not signed out, not
  in DEV, not while the sign-in is being answered).
- **It asks first** (`DeleteAccountDialog`, `delete-account-dialog`):
  **"Delete your account?"**, after listing the profile's accounts
  (`GET /api/auth/profile`) to tell the cases apart:
  - the owner: "You own the profile `<id>`. Deleting your account deletes
    the whole profile: its events, clips, recordings and settings in the
    cloud, its Feedback & Help messages, its recognition labels and its
    devices' stream keys.", and, when there are any, "These accounts
    linked to it lose access too: `<emails>`.";
  - a linked account: "`<email>` is linked to the profile `<id>`, owned by
    `<owner>`. Deleting your account unlinks it and deletes your Feedback &
    Help messages; the profile and its data stay its owner's.";
  - (when the list doesn't load, the owner's text, which says most;)
  - both: this device's copies of the profile's events and clips go too,
    and it signs out; it can't be undone;
  - **subscriptions**: on the web, "Deleting your account doesn't cancel
    a Premium subscription: cancel it first, from the link in your Stripe
    receipt, or ask us.", with **How to cancel a subscription**
    (`delete-account-subscriptions`), which opens
    `/delete-account#subscriptions` on the site (copied when it can't
    open); on iOS and Android, never naming Stripe ([Upgrade](upgrade.md)),
    "… cancel it first in your App Store (Google Play) subscription
    settings." with **Manage subscription**, which opens the store's
    subscriptions page;
  - a checkbox, **I understand that this can't be undone**
    (`delete-account-confirm`): **Delete account** (`delete-account-go`,
    error-colored) works only once it's ticked. **Cancel** deletes nothing.
- **Deleting** (`_deleteAccount`, [main.dart](../presence_app/lib/main.dart)),
  while the button spins:
  1. `POST /api/auth/account/delete` with the profile shown
     (`ProfileClient.deleteAccount`), asked again while the API answers
     that the cloud folder isn't empty yet (202), up to 20 times;
  2. once it's done, **signs out** first, so nothing more syncs for the
     profile (the event logged is "Account deleted", without the email,
     instead of "Signed out");
  3. **forgets the profile on this device** (`Persistence.deleteProfile`):
     every stored event of the profile, whichever device recorded it, for
     good, with the suggestions about its clips, the clips, their
     recordings and what cloud sync remembers of them (as [event
     retention](event-retention.md) deletes old ones); the other devices'
     media keys (`keys`, and in memory, `MediaKeys.forgetPeers`); and the
     settings' link to the profile. The devices hidden or taken off the
     list here are forgotten too. Events of no profile (recorded signed
     out) or of another profile stay, and so do this device's ID, key,
     consent, location and settings.
  4. closes the dialog and the sheet, and says **"Your account and its
     profile were deleted"** (owner) or **"Your account was deleted and
     unlinked from the profile"** (linked account).
- **When it fails**, the dialog stays, says why and can be tried again: a
  401 or 403 asks to sign in again; a 409 says the account's profile
  changed (close and try again); a 429 is "too many tries"; anything else
  "Couldn't delete the account (`<error>`). Try again.". A folder still not
  empty after 20 rounds says the cloud data is still being deleted, to try
  again in a minute (deleting carries on where it stopped). Nothing on the
  device changes until the API has finished.
- The strings are in English, Spanish and Portuguese (`authDeleteAccount*`,
  [Languages](i18n.md)).

## The API

`POST /api/auth/account/delete` on the [auth API](auth-api.md)
(`ProfileHandler.deleteAccount`), authenticated as the other profile
routes (the JWT authorizer, a verified email), for **any** signed-in
account, with or without roles. The body is the **profile ID** the app
shows: another one (or none) answers **409** and deletes nothing, so an
account that moved meanwhile isn't deleted by mistake.

- **No link** (never signed in, or already deleted): **200**
  `{"deleted": "nothing", "complete": true}`. Nothing is made for the
  caller, unlike the other routes, which make a profile at a first
  sign-in.
- **A linked account:** its Feedback and Help messages in the profile's
  conversation (those whose `email` is the caller's verified one) and its
  link (`ProfileSubjectsTable`) are deleted. **200** `{"deleted":
  "account", "profile", "accounts": 1, "objects": 0, "feedback",
  "identity": false, "complete": true}`.
- **The owner**, in this order:
  1. **the cloud folder**: every object under `<identityId>/` in the
     user-data bucket, listed 1000 at a time and deleted with
     `DeleteObjects`, until it's empty or 20 s pass (less if the function
     would time out first). Not empty yet: **202** `{"deleted": "profile",
     "profile", "objects": <deleted so far>, "complete": false}`, with
     nothing else deleted, and the app asks again. Only a prefix shaped
     like a Cognito identity ID (`<region>:<UUID>`,
     `ProfileBackend.IDENTITY_ID`) is ever deleted, never an empty or
     other one;
  2. the **Feedback and Help** conversation (`FeedbackTable`, keyed by the
     identity), every message, the administrators' replies too;
  3. the **identity**: live sync's IoT policy detached
     (`iot:DetachPolicy`; a failure is logged and doesn't stop it), then
     `DeleteIdentities` in the identity pool. A failure is logged with the
     identity, to delete by hand, and answers `"identity": false`; it
     doesn't stop the deletion;
  4. the **cloud recognition** labels and model (`RecognitionTable`, by
     profile);
  5. the devices' **stream keys** (`StreamKeysTable`, keyed
     `<profile>/<device>`, found with a scan for the prefix `<profile>/`);
  6. unused **link codes** into the profile (`LinkCodesTable`, keyed by
     their hash, found with a scan);
  7. every **other account's link**, then the **profile** row
     (`ProfilesTable`, with its devices list), and **last** the owner's
     own link.

  **200** `{"deleted": "profile", "profile", "accounts", "objects",
  "feedback", "recognition", "streamKeys", "identity", "complete": true}`.
- **Safe to retry:** each step does nothing when it's already done, and the
  caller's own link goes last, so a request that failed half-way (502, a
  timeout) is finished by the next. A profile that's gone, or bare (no
  owner and no folder: made again by a sign-in meanwhile), while the
  caller is still linked to it is one whose deletion stopped half-way:
  whoever calls finishes it as the owner's.
- **Keyed by the subject and the profile only** (`<iss>#<sub>`, the
  identity mapping the auth API keeps), so accounts of any sign-in
  provider are deleted the same way.
- **Not touched:** rbacr's roles and grants (kept by email; a subscription
  keeps working if the person comes back), the subscription itself, which
  must be cancelled where it was bought (Stripe, the App Store or Google
  Play), and the payments table's record of which store purchase belongs
  to the email ([Payments API](payments-api.md#storage)), so it can't be
  claimed by another account. The dialog and the web page say so.
- **Throttled** to 1 request a second (burst 5), for all callers together
  (see [Throttling and floods](auth-api.md#throttling-and-floods)). The
  profile function's timeout is 29 s (the HTTP API gives up at 30 s).
- **Without cloud sync set up** (no identity pool and bucket, locally by
  default) the tables are still deleted from; there's no folder or
  identity. Locally (`LocalCloudBackend`) the folder is Floci's bucket's
  and there's no identity to delete; there's no Feedback table.

### Least privilege

The profile function gains, for this route:

- `dynamodb:DeleteItem` on `ProfilesTable`; `dynamodb:Scan` on
  `LinkCodesTable` and `StreamKeysTable`; `dynamodb:Query` and
  `dynamodb:DeleteItem` on `RecognitionTable` and on the Feedback table
  (template parameter `FeedbackTable`, from the user-data stack's
  `FeedbackTableName`, which `deploy.sh` passes; `none` without one);
- `cognito-identity:DeleteIdentities` on this identity pool only;
- `s3:DeleteObject` on the user-data bucket's objects. The folder is the
  profile's identity, known only at run time, so IAM can't narrow it to
  one prefix: the function itself deletes only `<identity ID>/` of the
  caller's own profile;
- `iot:DetachPolicy` on `*`, beside `iot:AttachPolicy` (neither can be
  scoped to a Cognito identity).

The stage's permissions boundary (`<prefix>-app-boundary`,
[presence_infra/github-deploy.yaml](../presence_infra/github-deploy.yaml))
allows `cognito-identity:DeleteIdentities` and `iot:DetachPolicy` too; it
already allowed the rest. **The `presence-github-deploy` stack must be
updated by hand** (an administrator, as it was made) before the identity
and IoT steps work in AWS; until then they're logged as failures (the
identity is named, to delete by hand) and the rest of the deletion
completes.

## Without the app

[presence_index/site/delete-account/index.html](../presence_index/site/delete-account/index.html),
served at **`/delete-account`** like the [legal pages](legal.md) (the same
`legal.css`, no scripts; the CloudFront pages function maps it; the
deploy's smoke test checks its title, "Delete your account"):

- **In the app:** the steps above (Profile tab or the account picture,
  Delete account, tick, Delete account), on Android, iOS, Linux and the
  web.
- **Without the app:** write to julio@nu01.com **from the account's email
  address**, subject "Delete my Presence account"; it may be confirmed by
  a reply to that address; done within 30 days, and the person is told.
- **What is deleted:** the owner's and a linked account's cases, as above,
  and this device's copies.
- **What is kept, and for how long:** deleted cloud files stay as previous
  versions up to 30 days (the bucket's lifecycle), database backups up to
  35 days (point-in-time recovery); other devices still signed in keep
  their copies until their History setting deletes them (three months at
  most); rbacr keeps the email's access and Premium (deleted on request);
  Apple, Google or Stripe keep their payment records, and the payments
  API which store subscription was the account's; logs as the privacy
  policy says.
- **Subscriptions** (`#subscriptions`): deleting doesn't cancel Premium;
  cancel it where it was bought: the App Store's or Google Play's
  subscriptions (linked), or the Stripe receipt's link, or ask by email.

The Play Console's Data safety form gives this page as the deletion link.

## Tests

- Auth API (JUnit, `ProfileTest`): the owner deletes the whole profile
  (every account's link, codes, keys, folder, identity, feedback,
  recognition; both accounts' next sign-ins get new, empty profiles); a
  linked account only leaves (its own feedback only; the owner keeps
  everything); repeating answers "nothing" and makes nothing; another
  profile ID deletes nothing (409); a big folder takes more than one
  request (202, nothing else deleted until it's empty); a deletion stopped
  half-way is finished; an account without roles can delete itself;
  without cloud sync the tables are still deleted from.
- `ProfileBackendTest`: the folder deleted a page (1000) at a time, other
  folders untouched, even one whose name starts the same; stopping when
  the time is up; only an identity-shaped prefix (never empty, a region, a
  wildcard, a path); a refused deletion fails; the identity's IoT policy
  detached and the identity deleted, a failure reported, not thrown; the
  feedback (all, or a linked account's own, any case), recognition items,
  stream keys and link codes of the profile only (not one whose ID starts
  the same); nothing asked without the tables.
- Flutter (`delete_account_test.dart`): the HTTP client posts the profile
  and asks again until complete (summing the objects), gives up after its
  rounds, reads a linked account's and "nothing" answers, and throws on a
  refusal; the dialog's owner and linked texts, the checkbox before
  Delete, Cancel, failures (409, 401) shown and tried again, an
  unfinished folder, the subscriptions link, fitting 320 dp; the account
  sheet shows the button only with a profile and a way to delete;
  `Persistence.deleteProfile` deletes the profile's events, clips,
  recordings, suggestions, synced entries and peers' keys and nothing
  else; in the app, deleting calls the API, signs out, says so and forgets
  the profile's events in storage, keeping another profile's.

## Known limitations

- **Credentials already issued** keep working until they expire (up to an
  hour): a device of the profile still running may upload a little more
  after the folder is emptied. Those objects expire with the bucket's 90
  days.
- **Other devices** signed in to the profile keep their local copies until
  their History setting deletes them; their next sign-in check gets a new,
  empty profile.
- **A pre-profile folder** (a Google identity's from before profiles that
  was never the profile's) isn't deleted; the bucket expires it after 90
  days anyway.
- **Stream keys a linked account made** stay with the profile (they're its
  devices'), with that account's email as `createdBy`.
- **No undo**, and no grace period: the deletion is immediate.
- Requests by email are handled by hand.
