# Payments API

The Premium plans' **Stripe Payment Links**, monthly and yearly, which a
free member [upgrades to Premium](upgrade.md) with on the web (admins set
them in the Admin tab; until then, the deploy's), and the **App Store and
Google Play subscriptions** of the iOS and Android apps, which it verifies
with the store and grants in rbacr ([below](#store-purchases)). Its own
module,
[presence_api_payments/](../presence_api_payments): a SAM stack per stage
(**`presence-payments`**, **`presence-rc-payments`**) with one Java 25
Lambda (`PaymentsFunction`, `presence.payments.PaymentsHandler`), a
DynamoDB table and its own HTTP API, served under **`/api/payments/*`** by
the site's CloudFront distribution (origin `payments`, matched before the
auth API's `/api/*`; see [Production deploy](deploy.md)).

It never sees a Stripe payment: the links are Stripe's checkout pages,
and [rbacr](https://github.com/prodbytes/rbacr) syncs the Stripe account's
subscriptions into the `premium` role (see [Upgrade to
Premium](upgrade.md#how-it-becomes-premium)).

## Routes

A JWT authorizer refuses calls without a valid Presence
[session token](sessions.md) (401) before the function runs; only
Apple's notifications route has none. Its issuer is the auth API stack's
`SessionIssuer` output (`https://<site>`, passed by
`deploy.sh`), its audience `presence`. The caller is the token's email,
which the sign-in provider (Google or Apple) verified (`email_verified`,
always true in a session token), lowercased: `Identity.verifiedEmail`
([Identity.java](../presence_api_payments/PaymentsFunction/src/main/java/presence/payments/Identity.java)),
the one place a request's identity is read.

- **`GET /api/payments/links`** (any signed-in user; 20 requests/s, burst
  50): `{"monthly": "https://buy.stripe.com/…", "yearly": "…", "saved":
  true, "updatedAt": 1790000000000}`. What an admin saved, or until one
  does the stack's `MonthlyLink` and `YearlyLink` (`"saved": false`, no
  `updatedAt`). An empty link is a plan that isn't offered. Who saved them
  isn't answered.
- **`PUT /api/payments/links`** `{"monthly": "…", "yearly": "…"}` (1
  request/s, burst 5): saves both, and answers them as `GET` does.
  - Only **admins**: the caller's Google-verified email holds `admin` in
    rbacr's `presence` system, or is an rbacr root. rbacr is asked with the
    auth API's token (`POST /api/roles`, server-side; answers reused for
    60 s; fails closed). Anyone else: **403**.
  - The body is exactly those two keys, plain strings (no escapes), at
    most 2 KB; each link empty or an **HTTPS link on `stripe.com`** (or a
    subdomain), a path of URL-safe characters only (no query), at most 512
    characters. Otherwise **400**.
  - Saving replaces both: a field left empty stops offering that plan,
    even if the deploy has a default for it.
- **`GET /api/payments/store`**, **`POST /api/payments/store/verify`**
  and **`POST /api/payments/store/apple-notifications`**: store purchases,
  [below](#store-purchases).
- Other routes: 404. When DynamoDB fails: 502 with the request ID; the
  error goes to the function's log, the admin's email never does.

## Store purchases

Premium bought in the App Store (iOS) or Google Play (Android) as one of
two auto-renewing subscriptions, `presence.premium.monthly` and
`presence.premium.yearly` (`StorePurchase.PRODUCTS`), in the app
`com.nu01.presence` (`StorePurchase.APP_ID`) ([Upgrade to
Premium](upgrade.md#on-ios-and-android-the-stores)). Every purchase is
verified with its store, server-side; what the app says about product,
expiry or account is never trusted
([StorePurchases.java](../presence_api_payments/PaymentsFunction/src/main/java/presence/payments/StorePurchases.java)).

- **`GET /api/payments/store`** (any signed-in user; 20 requests/s, burst
  50): `{"ios": true, "android": false, "accountToken": "<uuid>"}`: which
  stores this stack verifies, and the account's token, a random UUID made
  once per email (`account:<email>` in the table; null while store
  purchases are off). The app puts it on its purchases (Apple's
  `appAccountToken`, Google's `obfuscatedAccountId`): it identifies the
  account to the stores without personal data. 403 without a verified
  email.
- **`POST /api/payments/store/verify`** `{"platform": "ios" | "android",
  "productId": "presence.premium.monthly", "verificationData": "…"}` (5
  requests/s, burst 20; the body at most 16 KB): `verificationData` is
  the plugin's `serverVerificationData`, StoreKit 2's signed transaction
  (JWS) on iOS and the purchase token on Android.
  - **iOS** (`AppleJws`, `AppleStore`): the JWS must be ES256 with an
    `x5c` chain of three certificates whose root is **Apple Root CA - G3**
    byte for byte (its DER is in the code, checked against its published
    SHA-256 fingerprint `63343abf…653e9179` at start); the chain must
    validate (PKIX) to it at the payload's `signedDate`, with Apple's OID
    `1.2.840.113635.100.6.2.1` on the intermediate and
    `1.2.840.113635.100.6.11.1` on the leaf, and the leaf's key must
    verify the signature. Then the payload must say `bundleId`
    `com.nu01.presence`, a Premium `productId` (the one sent), `type`
    `Auto-Renewable Subscription`, no `revocationDate`, an `expiresDate`
    in the future, and `environment` `Production`, or `Sandbox` where the
    stack allows it (`StoreAllowSandbox`). The purchase is its
    `originalTransactionId`, the same across renewals.
  - **Android** (`GooglePlay`): the token (URL-safe characters, 16 to
    2048) is looked up with the Android Publisher API,
    `purchases.subscriptionsv2.get` for package `com.nu01.presence`, as
    the service account in the Google Play secret (an OAuth token from its
    signed JWT, at `https://oauth2.googleapis.com/token` whatever the key
    file says, reused until a minute before it ends). The subscription
    must be `SUBSCRIPTION_STATE_ACTIVE` or `…_IN_GRACE_PERIOD`, with a
    line item of the `productId` sent whose `expiryTime` is in the future;
    a test purchase (`testPurchase`) only where the stack allows sandbox.
    After it's bound (below), it's **acknowledged** server-side if it
    wasn't (`purchases.subscriptions.acknowledge`; Google refunds a
    purchase not acknowledged within three days).
  - **Bound to the caller's email**, once and for good: a purchase
    (`purchase:ios:<originalTransactionId>`, or
    `purchase:android:<SHA-256 of the token>`) already bound to another
    email is **409**, and so is a purchase whose account token isn't the
    caller's, or a Google purchase whose `linkedPurchaseToken` (an upgrade
    or resubscription) is another email's.
  - **Granted in rbacr** (`RbacrGrants`): `premium` in the `presence`
    system to the email until the latest unrevoked bound purchase's end
    plus **2 days** (1 hour for sandbox and test purchases), with
    `POST /api/systems/presence/grants {role, grantee, endsAt}` and the
    grant token. It first asks `POST /api/check` how long the email holds
    `premium` already, and grants only when that's sooner, because rbacr
    replaces a grantee's grant with a new validity (G2), and a voucher's
    (forever), a root's or a domain's longer grant must stay. Verifying
    again after a renewal moves the end (G2). The end it granted is kept
    (`grantedUntil`).
  - Answers: **200** `{"premium": true, "platform", "productId",
    "expiresAt", "grantedUntil"}` (epoch ms; `grantedUntil` null when a
    longer grant was there already); **400** a body that isn't that, or a
    purchase the store doesn't vouch for (bad signature, another app,
    another product, expired, revoked, the sandbox where it isn't taken),
    with the reason; **403** no verified email; **409** another account's;
    **502** the store, Google's token service or rbacr failed (the
    purchase may be bound but not granted yet: the app tries again);
    **503** `{"error": "store purchases not configured"}` while the stack
    has no grant token (or, for Android, no Google Play secret).
- **`POST /api/payments/store/apple-notifications`** (no authorizer: 5
  requests/s, burst 20; the body at most 64 KB): App Store Server
  Notifications V2, `{"signedPayload": "…"}`, verified as above (the
  payload, its `signedTransactionInfo` and `signedRenewalInfo`), for
  `com.nu01.presence` and an environment the stack takes. Then, for a
  purchase already bound (its `originalTransactionId`):
  - `REFUND`, `REVOKE`, `EXPIRED`, `GRACE_PERIOD_EXPIRED`: the purchase
    ends now (revoked for a refund or revocation);
  - anything else (`SUBSCRIBED`, `DID_RENEW`, `DID_RECOVER`,
    `DID_CHANGE_RENEWAL_STATUS`, `DID_FAIL_TO_RENEW` with a grace period,
    …): its end becomes the transaction's `expiresDate`, or the renewal
    info's `gracePeriodExpiresDate` when later;
  - then the grant follows: extended as above while a bound purchase is
    current, else **revoked** (`DELETE /api/systems/presence/grants`) when
    rbacr's end is still the one this API granted, never someone else's.
  - 200 when handled, or for a `TEST` notification or a purchase that
    isn't bound yet (the app binds it when it verifies); 400 for anything
    Apple didn't sign for Presence; 502 when rbacr fails (Apple retries);
    503 while store purchases are off.
- **Not handled yet: Google's real-time developer notifications**
  (Pub/Sub push). Google renewals reach the API when the app verifies
  them (at sign-in, daily, and as the store reports them); a Google
  refund or revocation isn't seen, so its grant runs to its end.

The store routes never log a token, an email or the store's data: only
the platform, product and outcome.

## Storage

`PaymentsTable` (on-demand, encrypted, point-in-time recovery, kept when
the stack is deleted), keyed by `id`:

- **`links`**: `monthly`, `yearly`, `updatedAt` (epoch ms) and
  `updatedBy` (the admin's email);
- **`account:<email>`**: `accountToken` (the UUID), `purchases` (a set
  of the purchase items' keys) and `grantedUntil` (the end of the rbacr
  grant this API made last, epoch ms);
- **`purchase:ios:<originalTransactionId>`**,
  **`purchase:android:<SHA-256 of the purchase token>`**: `email` (set
  once, conditionally: never changed to another), `productId`,
  `expiresAt`, `revoked`, `updatedAt`.

It holds emails: AWS only.

## Deploying

`scripts/deploy.sh` deploys it after the auth API and the health check,
and passes its domain to the site stack (`PaymentsApiDomainName`):

- `SessionIssuer` (the auth API stack's output, which `deploy.sh` checks
  is `https://<site>`), `PermissionsBoundary`, and rbacr's
  `RbacrUrl`, `RbacrToken` and `RbacrSystem`, the auth API's;
- **`RbacrGrantToken`** (NoEcho): `RBACR_GRANT_TOKEN` from the
  environment (the `RBACR_GRANT_TOKEN` repository secret in CI), else
  `.env`; never logged. An API token owned by an **rbacr root**: only
  roots may grant and revoke (rbacr's P1), and asking how long someone
  else holds a role needs one too (T6). The auth API's `RBACR_TOKEN` is a
  root's, so it works; a separate token can be revoked on its own. Unset:
  **store purchases are off** (the verify route answers 503).
- **`GooglePlaySecretName`**: `GOOGLE_PLAY_SECRET` (the `GOOGLE_PLAY_SECRET`
  variable for GA, `GOOGLE_PLAY_SECRET_RC` for the RC, else `.env`): the
  Secrets Manager secret holding the Google service account's JSON key
  file, named under the stage's prefix (`presence/…`, `presence-rc/…`).
  The function may read that secret only (`secretsmanager:GetSecretValue`
  on its ARN), and the stage's permissions boundary allows only its own
  prefix (`StageSecrets` in
  [github-deploy.yaml](../presence_infra/github-deploy.yaml), which must
  be re-applied by hand once). The key is read when an Android purchase
  first needs it, once per instance, and never logged. Unset: Google Play
  purchases are off.
- **`StoreAllowSandbox`**: `STORE_ALLOW_SANDBOX` (`true` or `false`; the
  `STORE_ALLOW_SANDBOX` variable for GA): App Store sandbox purchases
  (TestFlight, App Review, sandbox testers) and Google Play test purchases
  (license testers) count. Default `true` for the RC, `false` for GA. App
  Review buys in the sandbox with the production build, so GA must allow
  it **while a build is in review** (and anyone with a TestFlight build
  gets Premium for free while it does).
- **`MonthlyLink`** and **`YearlyLink`**: `STRIPE_MONTHLY_LINK` and
  `STRIPE_YEARLY_LINK` from the environment, else `.env`, else the links
  in `deploy.sh`. GA and RC both default to
  `https://buy.stripe.com/dRm9AT6F71VfbaN1tl2Ji03` for both plans (the
  link given on 2026-10-11 for each). A variable set but empty offers
  no default for that plan; anything but an HTTPS stripe.com link stops
  the deploy.

The smoke test expects `GET /api/payments/links` without a token to
answer 401, and an unsigned `POST /api/payments/store/apple-notifications`
400 (503 while store purchases are off). The deploy roles need nothing
new: the stack, its function, role and table are named
`<prefix>-payments-…`, inside their scope. The function's role may get,
put and update items in its table only.

## In the app

- **`PaymentsService`**
  ([lib/auth/payments_client.dart](../presence_app/lib/auth/payments_client.dart))
  asks `GET /api/payments/links` (on the site's origin, `ApiConfig`) with
  the user's session token at each sign-in, and forgets the links at sign-out.
  Its `links` are null while unknown: signed out, loading, or when the API
  didn't answer. The app keeps only HTTPS stripe.com links of the answer.
- **The upgrade buttons** ([Upgrade to Premium](upgrade.md)) use them.

### In the Admin tab

**Payments** (`PaymentLinksEditor`,
[lib/auth/payment_links_editor.dart](../presence_app/lib/auth/payment_links_editor.dart)),
between Feedback and Vouchers and maintenance
([Membership](membership.md#the-admin-tab)):

- "The Stripe Payment Links free members upgrade to Premium with. Leave
  one empty not to offer that plan.";
- "Not saved yet: these are the deploy's links." while `saved` is false,
  or "The payments API didn't answer." (the fields disabled) when there
  are no links;
- **Monthly plan link** and **Yearly plan link**, filled with the
  current links; a field that isn't empty or an HTTPS stripe.com link
  without a query says "Empty, or an https link on stripe.com", and
  **Save links** stays disabled;
- **Save links** sends `PUT /api/payments/links`: "Payment links saved",
  and every upgrade button uses them at once; or "Couldn't save the links
  (…)" with the refusal (403 for a non-admin).

## Known limitations

- **Not in the local stack.** Floci deploys only the auth API; locally
  the links don't load, so the upgrade buttons open nu01.com and the
  Admin tab's Payments says the API didn't answer; a phone build pointed
  at it says purchases aren't available.
- **No online revocation check of Apple's certificates** (OCSP), as
  Apple's own libraries skip it offline: a JWS is checked against its
  chain as it was when signed.
- **A refund through Google Play isn't seen** (no real-time developer
  notifications yet); the grant runs to its end (the paid period plus 2
  days).
- **One purchase, one account, for good**: moving a store subscription
  to another Presence account means editing its item's `email` in the
  table by hand.
- **Not in `/health`.** The health check doesn't look at the payments
  table or API; the deploy's smoke test only checks that its route is
  live.
- **The deploy's defaults are both the same link** (2026-10-11): the
  monthly and the yearly button open the same checkout until an admin
  saves the yearly plan's own link.
- **No history:** saving replaces the links; the previous ones are only
  in DynamoDB's point-in-time recovery.
