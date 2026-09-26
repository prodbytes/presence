# Local CDN (`presence_floci`)

[presence_floci/](../presence_floci) runs [Floci](https://floci.io/), a
local AWS emulator, as the CloudFront distribution. It only routes, like the
deployed CloudFront would. The index, the app and the API run on their own
dev servers:

| Path | Origin |
|------|--------|
| default (`/`, anything else) | [Site index](site-index.md) (`python3 -m http.server`, 8081): `/` redirects to `/app/` |
| `/app*` | Flutter dev server (`flutter run`, hot reload), at **http://presence.localhost:4566/app/** |
| `/api/*` | `sam local start-api`: for now `GET /api/events` |

CloudFront forwards paths unchanged and can't strip a prefix, so each origin
serves its own prefix: the app has the `/app/` base href, and the API's
routes start with `/api/`. `/` redirects to `/app/` through the index
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
- The image is the dated nightly `nightly-09242026-compat`: Floci 2.1.0
  forwards no viewer headers to custom origins (not even `Authorization`).
  Move to the next release once it ships.
- The Flutter web server binds `127.0.0.1`, not `localhost`. Dart binds
  `localhost` to IPv6 `[::1]` only, which Docker Desktop's host gateway
  can't reach (Floci got a 502). Browsers still reach it at
  `http://localhost:8080/app/`.
- Settings: `FLOCI_PORT`, `PRESENCE_CDN_ALIAS`, `PRESENCE_ORIGIN_HOST`.
- Verified on macOS with Docker Desktop, under process-compose (the Flutter
  dev server, the SAM API, Floci and the health monitor):
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
  30 days or don't cover every name. The folder is git-ignored.
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
- On Linux, including the dev container, it doesn't reach the origins as
  is: plain Docker's `host-gateway` is the bridge address, not loopback.
- Google sign-in through this URL needs `http://presence.localhost:4566`
  added to the web OAuth client's authorized JavaScript origins.
