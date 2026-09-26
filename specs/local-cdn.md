# Local CDN (`presence_floci`)

[presence_floci/](../presence_floci) runs [Floci](https://floci.io/)
2.1.0, a local AWS emulator, as the CloudFront distribution in front of the
app and the API. **http://presence.localhost:4566/** serves `/events*` from
the SAM API and everything else from the Flutter web server, like the
deployed CloudFront would.

- It runs in a Docker container (`presence-floci`, compat image, bound to
  127.0.0.1) with `memory` storage. A `ready.d` init hook
  ([10-cloudfront.sh](../presence_floci/init/ready.d/10-cloudfront.sh))
  recreates the distribution on every start, with the stable alias
  `presence.localhost`.
- Both origins are `host.docker.internal`, allowlisted as private origins.
  Nothing is cached. Every viewer header except `Host`, plus all cookies and
  query strings, is meant to be forwarded (the equivalent of AWS's managed
  `AllViewerExceptHostHeader`, which Floci doesn't model).
- Settings: `FLOCI_PORT`, `PRESENCE_CDN_ALIAS`, `PRESENCE_ORIGIN_HOST`.
- The Flutter web server binds `127.0.0.1`, not `localhost`: Dart binds
  `localhost` to IPv6 `[::1]` only, and Docker Desktop's
  `host.docker.internal` reaches IPv4 loopback only, so Floci got a 502.
  Browsers still reach it at `http://localhost:8080`.
- Verified on macOS with Docker Desktop, under process-compose: `/` and the
  app's scripts returned 200 through Floci, `/events` returned the API's
  `{"events":[]}`, the health line showed `☁️ cdn ✅`, and shutdown removed
  the container.

## Known limitations

- In a browser, the app doesn't start through this URL: the Flutter dev
  server's debug channel can't pass through Floci, and 2.1.0 forwards no
  viewer headers to custom origins.
- On Linux, including the dev container, it doesn't reach the origins as
  is: they bind to 127.0.0.1, which `host.docker.internal` doesn't reach
  there.
- Google sign-in through this URL needs `http://presence.localhost:4566`
  added to the web OAuth client's authorized JavaScript origins.
