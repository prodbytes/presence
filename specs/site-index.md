# Site index (`presence_index`)

[presence_index/](../presence_index) is the site root. Its only page,
[site/index.html](../presence_index/site/index.html), redirects to the app
at `/app/`:

- a script redirect (`location.replace`), which keeps the query string (the
  hash is dropped, since the app's hash routing would read it as a route);
- a `meta refresh` for browsers without JavaScript;
- a plain "Open Presence" link as a last resort.

Only `site/` is served, so the module's README isn't.

- `devbox services up` serves it as `5-index`: Python's `http.server` on
  http://localhost:8081/ (`INDEX_PORT`), bound to 127.0.0.1, with a
  readiness probe on `/`.
- The CloudFront distribution in Floci uses it as the default origin (see
  [Local CDN](local-cdn.md)), so http://presence.localhost:4566/ redirects
  to http://presence.localhost:4566/app/.
- Edits to `site/` show up on the next request.
- Verified: headless Chrome opening `http://presence.localhost:4566/?x=1`
  ended on `http://presence.localhost:4566/app/?x=1` with the app loaded.
  `/README.md` and unknown paths return 404.
