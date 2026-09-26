# presence_api_events

The Presence events API: an [AWS SAM](https://aws.amazon.com/serverless/sam/)
application with one Java 25 Lambda function (`java25` runtime, arm64) behind
API Gateway.

| Path | Holds |
|------|-------|
| [template.yaml](template.yaml) | SAM template: `EventsFunction` and its `GET /events` route |
| [samconfig.toml](samconfig.toml) | Default `sam build` / `validate` / `deploy` settings (stack `presence-api-events`) |
| [EventsFunction/](EventsFunction) | Maven project for the function (`presence.api.events.EventsHandler`) |
| [events/event.json](events/event.json) | Sample API Gateway event for local invokes |

`GET /events` currently returns `{"events":[]}`; no store is wired in yet.

## Requirements

- [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html)
- JDK 25 and Maven 3.9+
- Docker, for `sam local` and `sam build --use-container`

## Commands

Run from this folder:

```bash
sam validate --lint                               # check the template
(cd EventsFunction && mvn test)                   # unit tests
sam build                                         # build the function
sam local invoke EventsFunction -e events/event.json
sam local start-api                               # http://127.0.0.1:3000/events
sam deploy --guided                               # first deploy; later just `sam deploy`
```

If `sam local` says it needs a container runtime while Docker Desktop is
running, point it at Docker's socket:
`export DOCKER_HOST=$(docker context inspect -f '{{.Endpoints.docker.Host}}')`.

The `/events` route has no authorizer yet, so a deployed stack is publicly
readable. Add one before it returns real data.
