# presence_index

The site root. Its only page, [site/index.html](site/index.html), sends
visitors to the app at `/app/`: a script redirect (`location.replace`,
keeping any query string), a `meta refresh` for browsers without
JavaScript, and a plain link as a last resort.

Only [site/](site) is served, so this README isn't.

## Running it

`devbox services up` serves it as `5-index`, on
http://localhost:8081/ (`INDEX_PORT`), with Python's `http.server` bound
to 127.0.0.1. The CloudFront distribution in Floci uses it as the
**default origin**, so http://presence.localhost:4566/ redirects to
http://presence.localhost:4566/app/. `/app*` and `/api/*` go to their own
origins (see [presence_floci/](../presence_floci)).

Edits to `site/` show up on the next request; nothing needs restarting.
