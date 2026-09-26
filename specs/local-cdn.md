# Local CDN (`presence_floci`)

[presence_floci/](../presence_floci) runs [Floci](https://floci.io/), a
local AWS emulator, as the CloudFront distribution. It only routes, like the
deployed CloudFront would. The app and the API run on their own dev servers:

| Path | Origin |
|------|--------|
| `/app*` | Flutter dev server (`flutter run`, hot reload), at **http://presence.localhost:4566/app/** |
| `/api/*` | `sam local start-api`: for now `GET /api/events` |
| everything else | Flutter dev server, which answers 404 outside `/app/` |

CloudFront forwards paths unchanged and can't strip a prefix, so each origin
serves its own prefix: the app has the `/app/` base href, and the API's
routes start with `/api/`. `/` isn't redirected to `/app/`, because that
needs a CloudFront Function, which Floci doesn't run.

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

## Known limitations

- On Linux, including the dev container, it doesn't reach the origins as
  is: plain Docker's `host-gateway` is the bridge address, not loopback.
- Google sign-in through this URL needs `http://presence.localhost:4566`
  added to the web OAuth client's authorized JavaScript origins.
