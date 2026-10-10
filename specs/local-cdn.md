# Local CDN (`presence_floci`)

[presence_floci/](../presence_floci) runs [Floci](https://floci.io/), a
local AWS emulator, as the CloudFront distribution. It only routes, like the
deployed CloudFront would. The index and the app run on their own dev
servers:

| Path | Origin |
|------|--------|
| default (`/`, anything else) | [Site index](site-index.md) (`python3 -m http.server`, 8081): `/` redirects to `/app/` |
| `/app*` | Flutter dev server (`flutter run`, hot reload), at **http://presence.localhost:4566/app/** |
| `/api/*` | The [auth API](auth-api.md), deployed into Floci itself (below) |

CloudFront forwards paths unchanged and can't strip a prefix, so each origin
serves its own prefix: the app has the `/app/` base href. `/` redirects to `/app/` through the index
page: an HTTP redirect would need a CloudFront Function, which Floci stores
but doesn't run.

- It runs in a Docker container (`presence-floci`, compat image, bound to
  127.0.0.1) with `memory` storage. A `ready.d` init hook
  ([10-cloudfront.sh](../presence_floci/init/ready.d/10-cloudfront.sh))
  recreates the distribution on every start, with the stable alias
  `presence.localhost`.
- Nothing is cached. Every viewer header except `Host` (including
  `Authorization`), plus all cookies and query strings, is forwarded, and
  all methods are allowed. It's the equivalent of AWS's managed
  `AllViewerExceptHostHeader`, which Floci doesn't model.
- **Hot reload through the CDN URL:** the Flutter dev server writes the
  `Host` it receives into its debug-channel WebSocket URL. Floci can't carry
  WebSockets, and it buffers streaming responses, so that channel must
  bypass it. Both origins are named `dev.presence.localhost`:
  - compose maps it to the Docker host (`host-gateway`) inside the
    container, and it's allowlisted as a private origin;
  - the browser resolves it to loopback, so the page's
    `ws://dev.presence.localhost:8080/app/…` connects to the dev server
    directly.
- The image is the dated nightly `nightly-09242026-compat`, pinned by its
  digest (`@sha256:eb725a12…`, the multi-arch index), since the container
  gets the Docker socket: Floci 2.1.0 forwards no viewer headers to custom
  origins (not even `Authorization`). Move to the next release once it
  ships, with its digest (`docker buildx imagetools inspect
  floci/floci:<tag>`).
- The Flutter web server binds `127.0.0.1`, not `localhost`. Dart binds
  `localhost` to IPv6 `[::1]` only, which Docker Desktop's host gateway
  can't reach (Floci got a 502). Browsers still reach it at
  `http://localhost:8080/app/`.
- Settings: `FLOCI_PORT`, `PRESENCE_CDN_ALIAS`, `PRESENCE_ORIGIN_HOST`.
- Verified on macOS with Docker Desktop, under process-compose (the Flutter
  dev server, the then-existing SAM API, Floci and the health monitor):
  - headless Chrome loaded http://presence.localhost:4566/app/ and the app
    rendered (camera view, Clip, Ready);
  - the debug WebSocket connected to `dev.presence.localhost:8080` (101);
  - `/api/events` returned `{"events":[]}`, and `/` and `/events` returned
    404;
  - the API origin received `Authorization`, cookies and query strings;
  - the health line showed `🌐 web ✅ ⚡ api ✅ ☁️ cdn ✅`, and shutdown left
    no containers.

## HTTPS

The distribution is also served over HTTPS at
**https://local.presence.nu01.com:8443/app/** and
https://presence.localhost:8443/app/ (and on 4566), with a local
certificate.

**`local.presence.nu01.com`** is a public name for this machine: an A record
to `127.0.0.1` in the Route 53 zone `nu01.com` (see the private repo for the account; TTL
300), and a second distribution alias (`PRESENCE_PUBLIC_HOST`). Google
rejects JavaScript origins that don't end in a public top-level domain, such
as `presence.localhost`, so **`https://local.presence.nu01.com:8443` is the
web client's local origin**.


- [scripts/local-certs.sh](../scripts/local-certs.sh) runs before Floci
  starts (in the `4-floci` command). With mkcert (from devbox), it writes
  `presence_floci/certs/presence.pem` and `presence-key.pem` for
  `local.presence.nu01.com`, `presence.localhost`, `*.presence.localhost`, `localhost`, `127.0.0.1`
  and `::1`. It regenerates them only when they're missing, expire within
  30 days, don't cover every name, or weren't signed by this machine's
  mkcert CA (a checkout shared with the dev container, which has its own
  CA). The folder is git-ignored.
- Floci loads them (`FLOCI_TLS_ENABLED`, `FLOCI_TLS_CERT_PATH`,
  `FLOCI_TLS_KEY_PATH`) and also listens for HTTPS on 8443
  (`FLOCI_TLS_AWS_HTTPS_PORT`; 8443 avoids a privileged port), published
  on 127.0.0.1 (`FLOCI_HTTPS_PORT`).
- Browsers trust the certificate once mkcert's CA is installed:
  `devbox run mkcert -install`, a one-time step that asks for the user's
  password. The `🔒 https` health check validates against the CA file
  (`mkcert -CAROOT`), so it doesn't depend on that step.
- Hot reload keeps working: the page's `ws://dev.presence.localhost:8080`
  channel is allowed from HTTPS, because `*.localhost` counts as a secure
  origin.
- Verified on macOS:
  - the served certificate's issuer is the mkcert development CA;
  - curl with the CA got 200 (`ssl_verify_result` 0) for `/app/` and
    `/api/events` on 8443, and for `/app/` on 4566;
  - curl without the CA was refused (exit 60);
  - headless Chrome loaded https://presence.localhost:8443/app/ with no
    failed requests (certificate errors overridden, because the CA isn't
    installed in the system store), the app started, and the debug
    WebSocket connected (101);
  - the health line showed `🔒 https ✅`.

## Known limitations

- `mkcert -install` needs the user's password, so it isn't automated.
  Until it's run, browsers warn about the certificate.
- On plain Linux Docker, `host-gateway` is the bridge address, not
  loopback, so origins bound to 127.0.0.1 are out of reach. The dev
  container sets `PRESENCE_BIND_HOST=0.0.0.0`, which the Flutter dev
  server and the index bind to (default 127.0.0.1); elsewhere on Linux,
  set it by hand. Verified in the dev container (docker-in-docker): the
  CDN answered 200 for `/app/` and `/`, and the health line was all ✅.
- Google sign-in through this URL needs `http://presence.localhost:4566`
  added to the web OAuth client's authorized JavaScript origins.

## The local auth API

At every start, Floci deploys the real auth API into itself, so sign-in,
profiles and account linking work locally without AWS. Roles, vouchers
and maintenance mode come from rbacr's RC, which the local web build
asks directly (see Roles below):

- **Build:** [scripts/build-auth-api.sh](../scripts/build-auth-api.sh) runs
  `sam build` before Floci starts (in the `4-floci` command), only when
  `presence_api_auth` changed. compose mounts the build read-only.
- **CPU:** the hook passes the host's architecture (`Architecture`:
  `arm64` on Apple silicon, `x86_64` on GitHub Codespaces), so Floci runs
  the Lambdas without emulation. AWS keeps the template's default,
  `arm64`.
- **Deploy:** the ready hook
  [05-auth-api.sh](../presence_floci/init/ready.d/05-auth-api.sh) deploys
  `template.yaml` as the stack `presence-local-auth-api`: the two Java 25
  Lambdas and their tables (`ProfilesTable`, `ProfileSubjectsTable`,
  `LinkCodesTable`). Floci
  runs the Lambdas as Docker containers (`presence-lambda-*`), which is
  why compose mounts the Docker socket. That gives Floci control of the
  Docker daemon, which is acceptable only for local development (its ports
  are bound to 127.0.0.1). Shutdown removes those containers.
- **The API in front:** CloudFront reaches private origins only when they
  are allowlisted by exact name, and CloudFormation gives the stack's HTTP
  API a random ID. The hook therefore also creates an HTTP API with the
  fixed ID `presence` (Floci's `floci:override-id` tag). It has the same
  Google JWT authorizer (issuer `https://accounts.google.com`, audience
  `GOOGLE_WEB_CLIENT_ID` from `.env`) and the template's routes:
  `GET /api/auth/anonymous` (`AuthFunction`) and the `ProfileFunction`
  routes (`POST /api/auth/credentials`, `GET /api/auth/profile`,
  `POST /api/auth/profile/link-code`, `/link`, `/unlink` and
  `/devices/remove`). `10-cloudfront.sh` then routes `/api/*` to
  `presence.execute-api.localhost.floci.io:4566`. Keep the hook's routes in
  step with `template.yaml`.
- **Roles** come from **rbacr's RC** (https://rc.rbacr.nu01.com, its own
  database), never GA rbacr, which prod uses. The local web build
  (`scripts/flutter-web.sh`) asks it directly with the user's ID token:
  `scripts/dart-defines.sh` passes `.env`'s `RBACR_RC_URL` and
  `RBACR_RC_SYSTEM` (default https://rc.rbacr.nu01.com and `presence`) as
  `RBACR_URL` and `RBACR_SYSTEM`, never `.env`'s `RBACR_URL` (which is
  for deploys; see [Configuration](configuration.md)). RC rbacr's CORS
  allows https://rc.presence.nu01.com, https://local.presence.nu01.com:8443
  and http://localhost:8080. The local auth API uses the same RC for a
  linked account's shared membership and the credentials' tier:
  `RBACR_RC_URL`, `RBACR_RC_TOKEN` (a token of an RC root) and
  `RBACR_RC_SYSTEM`, which `process-compose.yaml` passes to Floci as the
  stack's rbacr. The hook warns when a client is set but no token.
  Vouchers redeemed and maintenance switched locally are the RC's. The
  local monitor checks the RC's `/health`. Storage is `memory`, so every
  start begins with empty tables: profiles and links don't survive a
  restart (rbacr's grants do).
- **No `/health`:** the [health check](health-check.md)
  (`presence_health`) isn't deployed into Floci, and the distribution has
  no `/health` route: it checks AWS's identity pool and bucket, which the
  local Lambdas can't reach. The local stack still exports its three
  table names (`presence-local-auth-api-ProfilesTable`,
  `-ProfileSubjectsTable`, `-LinkCodesTable`), which Floci supports;
  nothing imports them.
- The hook runs past Floci's default 30 s, so compose sets
  `FLOCI_INIT_HOOKS_TIMEOUT_SECONDS` to 180, and the process's readiness
  allows 6 minutes (the first run builds and pulls the Lambda image).
- The public `GET /api/auth/anonymous` route is always created. Without
  `GOOGLE_WEB_CLIENT_ID` the API runs in **DEV** ([Execution
  mode](execution-mode.md)): the stack gets an empty client ID, and the
  hook creates no authorizer and none of the other routes. Without a build,
  the hook skips the API and `/api/*` isn't routed.
- `COGNITO_IDENTITY_POOL_ID` and `USER_DATA_BUCKET` from `.env` go to the
  stack too (`process-compose.yaml` reads them, compose passes them to
  Floci), so the route reports whether they're set. Without `.env` it
  answers
  `{"mode":"DEV","roles":[…every role…],"settings":{"oidc":false,"aws":false,"rbacr":false}}`.
- Through `https://local.presence.nu01.com:8443`, `/api/auth/profile`
  refuses a missing or forged token (401).

### Known limitations

- Floci answers a malformed bearer token with 406 when called directly
  (through CloudFront it's 401); AWS answers 401.
