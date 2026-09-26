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

## Settings

| Variable | Default | Meaning |
|----------|---------|---------|
| `FLOCI_PORT` | `4566` | Host port for Floci |
| `PRESENCE_CDN_ALIAS` | `presence.localhost` | Distribution alias (host name to browse) |
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
