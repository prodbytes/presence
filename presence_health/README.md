# presence_health

The site's health check, **`GET /health`**: an
[AWS SAM](https://aws.amazon.com/serverless/sam/) application with one
Java 25 Lambda (`java25`, arm64) behind its own API Gateway **HTTP API**,
served under **`/health`** by the site's CloudFront distribution and polled
by its Route 53 health check (see [specs/health-check.md](../specs/health-check.md)).

It checks, in parallel within 1.5 s, everything the
[auth API](../presence_api_auth) needs: its settings (an OIDC client, the
identity pool and the user-data bucket), its DynamoDB tables, the bucket,
the identity pool, Google's token signing keys and rbacr. It answers
**200** `{"status":"ok","checks":{…},"version":"X.Y.Z"}`, or **503** with
`"status":"fail"` and the failing checks; why a check failed goes only to
the function's log.

- **Its own stack per stage:** `presence-health` and `presence-rc-health`,
  deployed by [scripts/deploy.sh](../scripts/deploy.sh) right after the
  auth API stack, whose table exports (`<AuthStackName>-UserRolesTable`
  and so on) it imports. The function's role carries the stage's
  permissions boundary.
- **Read-only:** `dynamodb:DescribeTable` on the auth API's six tables,
  `s3:ListBucket` on the bucket (for `HeadBucket`) and
  `cognito-identity:DescribeIdentityPool` on the pool. It never gets
  rbacr's token, only its URL.
- **AWS only:** it isn't deployed into the local Floci.

| Path | Holds |
|------|-------|
| [template.yaml](template.yaml) | The HTTP API and the function |
| [HealthFunction/](HealthFunction) | Maven project (`presence.health.HealthHandler`) with its tests |
| [samconfig.toml](samconfig.toml) | Default `sam build` / `deploy` settings (stack `presence-health`) |

## Commands

From the repository root, inside devbox:

```bash
mvn -q -B -f presence_health/HealthFunction/pom.xml test   # unit tests
sam validate --lint -t presence_health/template.yaml
(cd presence_health && sam build)
```
