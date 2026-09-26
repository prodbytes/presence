# Events API (`presence_api_events`)

An AWS SAM application in [presence_api_events/](../presence_api_events):
one Java Lambda function, `EventsFunction`
(`presence.api.events.EventsHandler`), on the `java25` runtime (the latest
Lambda Java runtime) on arm64, behind an API Gateway REST API. It's built
with Maven (`maven.compiler.release` 25, a shaded jar).

- `GET /api/events` returns `200` with `{"events":[]}`. Its routes start
  with `/api/` because the CloudFront distribution sends `/api/*` to it
  unchanged. It's a scaffold: no event
  store is wired in yet, and the app doesn't call it.
- Stack name `presence-api-events` ([samconfig.toml](../presence_api_events/samconfig.toml)).
- Deployed to production by `*GA` tags, behind https://presence.nu01.com/api/
  (see [Production deploy](deploy.md)); its `ApiDomain` output is the
  CloudFront origin. The commands are in the module's
  [README](../presence_api_events/README.md).
- Runs locally under `devbox services up` (see
  [Development environment](dev-environment.md)).

## Known limitations

- The route has no authorizer, so a deployed stack would be publicly
  readable.
