# Origin check

The APIs answer **only through the site's CloudFront distribution**, never
at their own `execute-api` hosts. CloudFront adds a secret header to every
request it sends them, and each API function refuses a request without it.
It's the APIs' version of the site bucket's origin access control: the
secret never leaves AWS, and no client holds it, so the app (web,
Android, desktop) and presence-streamer need nothing new. They already
call `https://presence.nu01.com/api/...` (or the RC site).

## What it does and doesn't stop

- **Stops**: calls to the APIs' `execute-api` hosts that skip CloudFront,
  and with them anything only CloudFront applies (the site's headers,
  and a future WAF; see [Auth API](auth-api.md), "Throttling and floods").
- **Doesn't stop**: a script calling through the site's domain with a
  user's own [session token](sessions.md), exactly as the app does. Nothing a client
  holds can prove the call came from the app's code; only attestation
  could (Play Integrity, App Attest, a WAF browser challenge), which isn't
  done. A key the app fetched at start would add nothing: a script fetches
  it the same way.

## How

- **The header**: `x-presence-origin-verify`, on the distribution's three
  API origins (`api`, `payments`, `health`; `OriginCustomHeaders` in
  [site.yaml](../presence_infra/site.yaml), from its `OriginSecret`
  parameter, NoEcho). CloudFront overwrites a viewer's header of the same
  name, so a caller can neither set nor read it.
- **The check** (`OriginCheck`, one copy in each API module: auth,
  payments, health): the first thing every handler does (`AuthHandler`,
  `ProfileHandler`, the three recognition handlers, `PaymentsHandler`,
  `HealthHandler`). Without the header, or with another value (compared in
  constant time), it answers **403** `{"error":"use the site:
  https://presence.nu01.com"}`. Token routes check the session token first
  (the API's authorizer, 401), then this. With no secret configured
  (`ORIGIN_SECRET` empty) every request passes.
- **Each function** gets `ORIGIN_SECRET` from its stack's `OriginSecret`
  parameter (NoEcho; the auth API's through `Globals`, so every function
  has it).
- **The secret** (`scripts/deploy.sh`): `ORIGIN_SECRET` from the
  environment or `.env` (32 or more of letters, digits, `_` and `-`), or
  else derived: the HMAC-SHA256 of `presence-origin-<stage>` keyed with
  `RBACR_TOKEN`, so prod and RC differ and CI needs no other secret. It's
  never logged nor stored outside the stacks' parameters, the functions'
  configuration and the distribution's.

## Rollout

`deploy.sh` deploys the APIs before the site, so they mustn't refuse
requests the site doesn't sign yet:

- The site's `OriginVerified` output says whether it sends the header.
  The APIs get the secret (and enforce it) only when it's already
  `true`; otherwise they get it empty.
- So the **first deploy** with this has the site start sending it, and
  the APIs keep answering everyone; **from the next deploy**, the APIs
  enforce it. Two releases (RC and GA each) turn it on, with no moment
  where the site is refused.
- Once enforced, the **smoke test** also requires the auth API's host
  (`/api/auth/anonymous`) and the health check's (`/health`) to answer
  **403** when called directly. The site's own checks passing shows it
  sends the right secret.

## Local

The local stack (Floci) doesn't pass a secret, so its APIs answer
directly, as before ([Local CDN](local-cdn.md)).

## Verified

- `OriginCheckTest` in each module (auth, payments, health): with a
  secret, only a request carrying it passes (any header case); a wrong,
  empty or missing value, or none at all, is refused with 403; without a
  secret (none, empty, blank) everything passes. Every module's tests pass
  with the check in every handler (the tests set no secret).
- `cfn-lint` passes on the four templates; `deploy.sh` parses (`bash -n`);
  the derived secret is stable and differs by stage.
- **Not yet run in AWS**: the first deploy, the second (enforcing) and
  its smoke test.

## Known limitations

- **Changing the secret** (`ORIGIN_SECRET`, or `RBACR_TOKEN` when it's
  derived) makes the APIs refuse the site for the minutes between their
  deploy and the site's (CloudFront takes a few minutes); if the site's
  deploy then fails, until it's fixed. They accept one secret at a time.
- The secret is readable by anyone in the AWS account who can read the
  functions' configuration or the distribution's.
- Requests through the site with a valid token aren't told apart from the
  app's (above).
