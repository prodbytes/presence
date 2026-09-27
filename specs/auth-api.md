# Auth API (`auth_api`)

[auth_api/](../auth_api) is a SAM application: one Java 25 Lambda
(`presence.auth.AuthHandler`, arm64) behind an API Gateway HTTP API, at
**`GET /api/auth`** on the site (`/api/*` in the CloudFront distribution;
see [Production deploy](deploy.md)). It returns the signed-in user's roles:
`{"email": "...", "roles": [...]}`.

- **Authentication:** the HTTP API's **JWT authorizer** verifies the Google
  ID token in `Authorization: Bearer …`: issuer `https://accounts.google.com`,
  and audience the web OAuth client, so tokens for other apps are refused.
  Otherwise it answers 401 before the function runs. The function only reads
  the verified claims (`email`, `email_verified`).
- **Roles:**
  - nobody has roles by default;
  - a verified email whose domain is exactly `PrivilegedDomain` (`nu01.com`)
    gets `DomainRoles` (`admin`);
  - the **`UserRolesTable`** DynamoDB table declares roles per user, keyed by
    lowercase `email`, with `roles` as a string set or list. They're added
    to any domain roles.
  - Unverified emails get nothing. `sub.nu01.com`, `evilnu01.com` and
    `nu01.com.example` don't count as the domain.
- **The table:** on-demand, encrypted, with point-in-time recovery, and kept
  if the stack is deleted. The function may only read it. Its contents
  (people's emails) live only in AWS.
- **The response** is `application/json` with `Cache-Control: no-store`, and
  CloudFront doesn't cache `/api/*` either.
- **Deploy:** `scripts/deploy.sh` runs `sam build` and `sam deploy` (stacks
  `presence-auth-api` and `presence-rc-auth-api`) before the site, and passes
  the stack's `ApiDomain` output to `site.yaml`. The smoke test requires
  `/api/auth` to answer **401** without a token, which proves the route and
  its authorizer are live.
- **Tests** (JUnit, `mvn test`):
  - the role rules: default none, the exact domain, verification, table
    roles, case and whitespace;
  - the handler's JSON: roles, no roles, no claims, escaping.
