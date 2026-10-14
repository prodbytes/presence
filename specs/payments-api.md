# Payments API

The Premium plans' **Stripe Payment Links**, monthly and yearly, which a
free member [upgrades to Premium](upgrade.md) with. Admins set them in the
Admin tab; until then, the deploy's. Its own module,
[presence_api_payments/](../presence_api_payments): a SAM stack per stage
(**`presence-payments`**, **`presence-rc-payments`**) with one Java 25
Lambda (`PaymentsFunction`, `presence.payments.PaymentsHandler`), a
DynamoDB table and its own HTTP API, served under **`/api/payments/*`** by
the site's CloudFront distribution (origin `payments`, matched before the
auth API's `/api/*`; see [Production deploy](deploy.md)).

It never sees a payment: the links are Stripe's checkout pages, and
[rbacr](https://github.com/prodbytes/rbacr) syncs the Stripe account's
subscriptions into the `premium` role (see [Upgrade to
Premium](upgrade.md#how-it-becomes-premium)).

## Routes

A JWT authorizer refuses calls without a valid Presence
[session token](sessions.md) (401) before the function runs: issuer the
auth API stack's `SessionIssuer` output (`https://<site>/api/auth`, the
stack's `SessionIssuer` parameter, from `deploy.sh`), audience
`presence`. The function reads the caller's `email` and `email_verified`
in one place (`PaymentsHandler.verifiedEmail`).

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
- Other routes: 404. When DynamoDB fails: 502 with the request ID; the
  error goes to the function's log, the admin's email never does.

## Storage

`PaymentsTable` (on-demand, encrypted, point-in-time recovery, kept when
the stack is deleted), keyed by `id`. One item, **`links`**: `monthly`,
`yearly`, `updatedAt` (epoch ms) and `updatedBy` (the admin's email). It
holds an email: AWS only.

## Deploying

`scripts/deploy.sh` deploys it after the auth API and the health check,
and passes its domain to the site stack (`PaymentsApiDomainName`):

- `GoogleWebClientId`, `PermissionsBoundary`, and rbacr's `RbacrUrl`,
  `RbacrToken` and `RbacrSystem`, the auth API's;
- **`MonthlyLink`** and **`YearlyLink`**: `STRIPE_MONTHLY_LINK` and
  `STRIPE_YEARLY_LINK` from the environment, else `.env`, else the links
  in `deploy.sh`. GA and RC both default to
  `https://buy.stripe.com/dRm9AT6F71VfbaN1tl2Ji03` for both plans (the
  link given on 2026-10-11 for each). A variable set but empty offers
  no default for that plan; anything but an HTTPS stripe.com link stops
  the deploy.

The smoke test expects `GET /api/payments/links` without a token to
answer 401. The deploy roles need nothing new: the stack, its function,
role and table are named `<prefix>-payments-…`, inside their scope.

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
  Admin tab's Payments says the API didn't answer.
- **Not in `/health`.** The health check doesn't look at the payments
  table or API; the deploy's smoke test only checks that its route is
  live.
- **The deploy's defaults are both the same link** (2026-10-11): the
  monthly and the yearly button open the same checkout until an admin
  saves the yearly plan's own link.
- **No history:** saving replaces the links; the previous ones are only
  in DynamoDB's point-in-time recovery.
