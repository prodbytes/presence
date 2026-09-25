# presence_floci

Runs [Floci](https://floci.io/), a local AWS emulator, as the Presence
**CloudFront** distribution. One URL serves both the Flutter web app and the
SAM events API, routed by path as the deployed CloudFront would:

| Path | Origin |
|------|--------|
| `/events*` | SAM API, `sam local start-api` (`SAM_API_PORT`, 3000) |
| everything else | Flutter web server (`FLUTTER_WEB_PORT`, 8080) |

Open **http://presence.localhost:4566/**. Browsers and curl resolve
`*.localhost` to loopback, so no hosts-file edit is needed.

## Files

| Path | Holds |
|------|-------|
| [compose.yaml](compose.yaml) | The `presence-floci` container (`floci/floci:2.1.0-compat`), bound to 127.0.0.1 |
| [init/ready.d/10-cloudfront.sh](init/ready.d/10-cloudfront.sh) | Ready hook: creates the cache policy, origin request policy and distribution |

## How it works

- `devbox services up` starts it as `4-floci`. The process is ready once
  Floci reports its `ready` hooks done (`/_floci/init`).
- Storage is `memory`, so every start is clean and the hook recreates the
  distribution. The distribution ID changes each time; use the alias.
- Both origins are `host.docker.internal`, which Floci allows through
  `FLOCI_SERVICES_CLOUDFRONT_ALLOWED_PRIVATE_ORIGIN_HOSTS`. By default it
  refuses private origins.
- Nothing is cached (all TTLs are 0). Every viewer header except `Host` is
  forwarded, with all cookies and query strings, matching AWS's managed
  `AllViewerExceptHostHeader` policy. Floci doesn't model AWS managed
  policies, so the hook creates equivalents.
- The API behavior allows all methods. The app behavior allows GET, HEAD and
  OPTIONS.
- The health monitor's `☁️ cdn` check requests `/` with the alias as the
  `Host` header.

## Settings

| Variable | Default | Meaning |
|----------|---------|---------|
| `FLOCI_PORT` | `4566` | Host port for Floci |
| `PRESENCE_CDN_ALIAS` | `presence.localhost` | Distribution alias (host name to browse) |
| `PRESENCE_ORIGIN_HOST` | `host.docker.internal` | Where Floci finds the web app and API |

## Limitations

- **Linux (incl. the dev container):** the Flutter web server and SAM bind to
  `localhost`, so a container can't reach them through `host.docker.internal`
  (Docker Desktop on macOS forwards to the host's loopback; plain Docker on
  Linux doesn't). Point `PRESENCE_ORIGIN_HOST` at an address the servers
  listen on, or run Floci with host networking.
- **Google sign-in** only works on origins registered with the OAuth client.
  Add `http://presence.localhost:4566` to the web client's authorized
  JavaScript origins to sign in through the CDN URL.
- CloudFront Functions aren't executed and there's no edge caching (see the
  [Floci CloudFront docs](https://github.com/floci-io/floci/blob/main/docs/services/cloudfront.md)).
- A POST to `/events` returns 405 through Floci but 403 from SAM directly,
  because the API defines only GET. Non-GET forwarding hasn't been exercised
  against a route that accepts it.
