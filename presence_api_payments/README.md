# presence_api_payments

The payments API: the **Stripe Payment Links** a free member upgrades to
Premium with, monthly and yearly. An
[AWS SAM](https://aws.amazon.com/serverless/sam/) application with one Java
25 Lambda (`java25`, arm64), a DynamoDB table and its own API Gateway
**HTTP API**, served under **`/api/payments/*`** by the site's CloudFront
distribution (see [specs/payments-api.md](../specs/payments-api.md)).

- **`GET /api/payments/links`** (any signed-in user):
  `{"monthly": "https://buy.stripe.com/…", "yearly": "…", "saved": true,
  "updatedAt": 1790000000000}`. What an admin saved, or until then the
  stack's `MonthlyLink` and `YearlyLink` (`"saved": false`). An empty link
  is a plan that isn't offered.
- **`PUT /api/payments/links`** `{"monthly": "…", "yearly": "…"}` (admins:
  `admin` in rbacr's `presence` system, or an rbacr root): saves both. Each
  must be empty or an HTTPS link on `stripe.com`, at most 512 characters,
  with no query. 403 for anyone else, 400 otherwise.
- A JWT authorizer refuses calls without a valid Presence session token
  (401) before the function runs: issuer the auth API's (`SessionIssuer`,
  `https://<site>/api/auth`), audience `presence` (see
  [specs/sessions.md](../specs/sessions.md)).

It never sees a payment: the links are Stripe's checkout pages, and rbacr
syncs the Stripe account's subscriptions into the `premium` role.

- **Its own stack per stage:** `presence-payments` and
  `presence-rc-payments`, deployed by [scripts/deploy.sh](../scripts/deploy.sh)
  with `STRIPE_MONTHLY_LINK` and `STRIPE_YEARLY_LINK` as the defaults and
  the auth API's rbacr URL and token.
- **The table** (`PaymentsTable`, kept on stack deletion, point-in-time
  recovery) holds one item, `links`, with the admin's email who saved it.
- **Not in the local stack** (Floci): the app falls back to nu01.com when
  the API doesn't answer.

Tests: `mvn test` in `PaymentsFunction/` (inside `devbox shell`).
