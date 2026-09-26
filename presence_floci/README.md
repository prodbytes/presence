# presence_floci

Runs [Floci](https://floci.io/), a local AWS emulator, as the Presence
**CloudFront** distribution. It only routes, as the deployed CloudFront
would. The app and the API keep running on their own dev servers:

| Path | Origin |
|------|--------|
| default (`/`, anything else) | `presence_index`, Python `http.server` (`INDEX_PORT`, 8081): `/` redirects to `/app/` |
| `/app*` | Flutter dev server, `flutter run -d web-server --base-href /app/` (`FLUTTER_WEB_PORT`, 8080) |
| `/api/*` | SAM API, `sam local start-api` (`SAM_API_PORT`, 3000); for now `GET /api/events` |

Open **http://presence.localhost:4566/** (it redirects to `/app/`) or **http://presence.localhost:4566/app/**. Browsers and curl resolve
`*.localhost` to loopback, so no hosts-file edit is needed.

CloudFront forwards paths as is (it can't strip a prefix), so each origin
serves its own prefix: the app has the `/app/` base href, and the API routes
start with `/api/`.

## Files

| Path | Holds |
|------|-------|
| [compose.yaml](compose.yaml) | The `presence-floci` container, bound to 127.0.0.1 |
| [init/ready.d/10-cloudfront.sh](init/ready.d/10-cloudfront.sh) | Ready hook: creates the cache policy, origin request policy and distribution |
| `certs/` (git-ignored) | The local HTTPS certificate and key, from [scripts/local-certs.sh](../scripts/local-certs.sh) |

## How it works

- `devbox services up` starts it as `4-floci`. The process is ready once
  Floci reports its `ready` hooks done (`/_floci/init`).
- Storage is `memory`, so every start is clean and the hook recreates the
  distribution. The distribution ID changes each time; use the alias.
- Nothing is cached (all TTLs are 0). Every viewer header except `Host`, plus
  all cookies and query strings, is forwarded (including `Authorization`),
  matching AWS's managed `AllViewerExceptHostHeader` policy. Floci doesn't
  model AWS managed policies, so the hook creates an equivalent. All
  methods are allowed.
- **Hot reload works through the CDN URL.** The Flutter dev server writes
  the `Host` it receives into its debug-channel WebSocket URL. Floci can't
  carry WebSockets (it drops `Upgrade`) and buffers streaming responses, so
  that channel mustn't go through it. Both origins are therefore named
  `dev.presence.localhost`:
  - Inside the container, compose maps it to the Docker host
    (`host-gateway`), and it's allowlisted as a private origin
    (`FLOCI_SERVICES_CLOUDFRONT_ALLOWED_PRIVATE_ORIGIN_HOSTS`).
  - In the browser, it's loopback, so the page's
    `ws://dev.presence.localhost:8080/app/$dwdsSseHandler` goes straight
    to the dev server.
- The image is a dated nightly (`nightly-09242026-compat`): Floci 2.1.0
  forwards no viewer headers at all to custom origins. Move to the next
  release once it ships.
- The health monitor's `☁️ cdn` check requests `/app/` with the alias as the
  `Host` header.

## HTTPS

Floci also serves the distribution over **HTTPS** with a local certificate:
**https://local.presence.nu01.com:8443/app/** or
https://presence.localhost:8443/app/ (and on 4566, which answers HTTP and
HTTPS). The API is at `…:8443/api/events`.

`local.presence.nu01.com` resolves to `127.0.0.1` (an A record in the
Route 53 zone `nu01.com`) and is the distribution's second alias. Use it for
Google sign-in: Google only accepts JavaScript origins with a public
top-level domain, so the web OAuth client lists
`https://local.presence.nu01.com:8443`.

- [scripts/local-certs.sh](../scripts/local-certs.sh) runs before Floci
  starts. With [mkcert](https://github.com/FiloSottile/mkcert) (from
  devbox), it writes `certs/presence.pem` and `certs/presence-key.pem` for
  `local.presence.nu01.com`, `presence.localhost`, `*.presence.localhost`,
  `localhost`, `127.0.0.1` and `::1`. It regenerates them only when they're missing, expire within
  30 days or don't cover every name. `certs/` is git-ignored.
- compose mounts `certs/` read-only and sets `FLOCI_TLS_ENABLED`,
  `FLOCI_TLS_CERT_PATH`, `FLOCI_TLS_KEY_PATH` and
  `FLOCI_TLS_AWS_HTTPS_PORT=8443`. 8443, rather than the default 443,
  avoids binding a privileged port.
- The certificate is signed by mkcert's local CA (`mkcert -CAROOT`). **To
  have browsers trust it, run once:** `devbox run mkcert -install`. It asks
  for your password, because it adds the CA to the system trust store.
  Until then, curl and the health check validate against the CA file
  directly, and browsers show a certificate warning.
- Hot reload still works over HTTPS: the dev server's `ws://` channel to
  `dev.presence.localhost` is allowed from an HTTPS page, because browsers
  treat `*.localhost` as a secure origin.
- The health monitor's `🔒 https` check fetches `/app/` over HTTPS and
  validates the certificate against mkcert's CA.

## Settings

| Variable | Default | Meaning |
|----------|---------|---------|
| `FLOCI_PORT` | `4566` | Host port for Floci (HTTP and HTTPS) |
| `FLOCI_HTTPS_PORT` | `8443` | Host port for Floci's HTTPS-only listener |
| `PRESENCE_CDN_ALIAS` | `presence.localhost` | Distribution alias (host name to browse) |
| `PRESENCE_PUBLIC_HOST` | `local.presence.nu01.com` | Second alias, with a public TLD, for OAuth origins; also in the certificate |
| `PRESENCE_ORIGIN_HOST` | `dev.presence.localhost` | Origin host name: the Docker host inside the container, and loopback in the browser |

## Limitations

- **Linux (incl. the dev container):** the Flutter dev server and SAM bind to
  127.0.0.1. On plain Docker, `host-gateway` is the bridge address, which
  can't reach them (Docker Desktop on macOS forwards it to the host's
  loopback). Running Floci with host networking would fix this.
- **Google sign-in** only works on origins registered with the OAuth client.
  Add `http://presence.localhost:4566` to the web client's authorized
  JavaScript origins to sign in through the CDN URL.
- There's no edge caching (see the
  [Floci CloudFront docs](https://github.com/floci-io/floci/blob/main/docs/services/cloudfront.md)).
