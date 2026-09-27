# presence_api_auth

The Presence auth API: an [AWS SAM](https://aws.amazon.com/serverless/sam/)
application with one Java 25 Lambda (`java25`, arm64) behind an API Gateway
**HTTP API**, served at **`/api/auth`** by the site's CloudFront
distribution.

`GET /api/auth` with `Authorization: Bearer <Google ID token>` returns the
caller's roles:

```json
{"email": "someone@example.com", "roles": []}
```

- **Who's calling:** the HTTP API's JWT authorizer checks the Google ID
  token first: signature, expiry, issuer `https://accounts.google.com`, and
  audience the web client ID (`GoogleWebClientId`). A missing, expired,
  forged or foreign token gets **401** and never reaches the function. The
  function reads the verified `email` and `email_verified` claims.
- **Roles** ([Roles.java](AuthFunction/src/main/java/presence/auth/Roles.java)):
  - none by default;
  - a **verified** email at `PrivilegedDomain` (default `nu01.com`,
    matched exactly after the `@`) gets `DomainRoles` (default `admin`);
  - anyone listed in the **`UserRolesTable`** DynamoDB table gets the roles
    declared there, added to any domain roles. The table is keyed by
    lowercase `email`, with `roles` as a string set or a list of strings.
- The table's contents live only in AWS, never in this repository. For
  example:

  ```bash
  aws dynamodb put-item --table-name "<UserRolesTableName output>" \
    --item '{"email": {"S": "someone@example.com"}, "roles": {"SS": ["viewer"]}}'
  ```

| Path | Holds |
|------|-------|
| [template.yaml](template.yaml) | The table, the HTTP API with its Google JWT authorizer, and the function (read-only access to the table) |
| [AuthFunction/](AuthFunction) | Maven project (`presence.auth.AuthHandler`, `Roles`) with its tests |
| [samconfig.toml](samconfig.toml) | Default `sam build` / `deploy` settings (stack `presence-auth-api`) |

## Commands

From this folder, inside devbox:

```bash
(cd AuthFunction && mvn test)   # unit tests
sam validate --lint
sam build
```

`scripts/deploy.sh` deploys it as `presence-auth-api` (or
`presence-rc-auth-api` with `STAGE=rc`), passing the site's web client ID.
