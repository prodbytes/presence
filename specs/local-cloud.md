# Local cloud

On the local stack (`devbox services up`), cloud sync and live sync run
against **Floci**, the local AWS emulator, instead of AWS: the profile's
credentials, the user-data bucket and the MQTT broker are all local, and
nothing reaches production. The web app at http://localhost:8080/app/
(and through the local CDN) syncs with the bucket and the other local
devices as the deployed one does with AWS.

## Why

Floci emulates S3, STS and AWS IoT's MQTT broker, but not Cognito
Identity's `GetId`, `GetOpenIdTokenForDeveloperIdentity` and
`GetCredentialsForIdentity` (it answers `UnknownOperationException`), which
the auth API and the app use for credentials in AWS. So the local auth API
stands in for Cognito, and the app reaches Floci instead of AWS.

## How

- **The auth API, `LocalCloud=true`** (stack parameter, `LOCAL_CLOUD` on
  `ProfileFunction`; only `presence_floci/init/ready.d/05-auth-api.sh`
  sets it, and `scripts/deploy.sh` passes `false`):
  `LocalCloudBackend` ([LocalCloudBackend.java](../presence_api_auth/AuthFunction/src/main/java/presence/auth/LocalCloudBackend.java))
  - makes up a Google account's identity from its token's `iss` and `sub`
    (which the JWT authorizer verified): `us-east-1:<UUID of
    "presence-local|<iss>#<sub>">`, the same every time, as `GetId`
    would be;
  - answers `POST /api/auth/credentials` with `"credentials"` itself, in
    Cognito's shape (`AccessKeyId` `ASIALOCAL…`, `SecretKey`,
    `SessionToken`, `Expiration` an hour on), random, which Floci accepts
    without checking; `"token"` is `local`;
  - attaches no IoT policy (Floci's broker has none), and reaches Floci's
    S3 path-style; link codes, profiles and devices are Floci's DynamoDB,
    as before.
- **The app** ([lib/cloud/](../presence_app/lib/cloud)):
  - `CognitoCredentials` uses the answer's `credentials` when it has them,
    and doesn't call Cognito;
  - `S3Bucket` takes an `endpoint` (`CloudConfig.awsEndpoint`, the build's
    `AWS_ENDPOINT`, HTTPS or HTTP to localhost only): requests go
    path-style to `<endpoint>/<bucket>/<key>`, signed for that host;
  - live sync's `IOT_ENDPOINT` may be `ws://localhost:4566`: the URL is
    presigned as for AWS IoT, with `ws://` and that port (the MQTT
    clients now take the port from the URL; 443 for AWS's `wss://`).
- **The build** (`scripts/dart-defines.sh`): `PRESENCE_LOCAL_CLOUD=1`,
  which `scripts/flutter-web.sh` sets unless it's `0`, overrides the
  environment and `.env` with `COGNITO_IDENTITY_POOL_ID=local` (a
  placeholder: cloud sync needs one set), `USER_DATA_BUCKET=presence-local-user-data`,
  `IOT_ENDPOINT=ws://localhost:4566`, `AWS_ENDPOINT=https://localhost:8443`,
  and no `FEEDBACK_TABLE`. Phone, release and deploy builds don't set it.
- **Floci** (`presence_floci/init/ready.d/03-local-cloud.sh`, before the
  auth API): the bucket `presence-local-user-data`, with CORS for the
  local origins (https://local.presence.nu01.com:8443,
  https://presence.localhost:8443, http://presence.localhost:4566,
  http://localhost:8080; `GET`, `PUT`, `HEAD`, `DELETE`, `ETag` exposed).
  `process-compose.yaml` gives the local auth API the same bucket and the
  placeholder pool, so it reports `"aws":true`. Floci keeps nothing
  between starts (memory storage), so neither does the local cloud.
- **The health monitor** (`scripts/health-check.sh`): ☁️ AWS is ✅ when the
  API reports it set and Floci has the local bucket; ❌ only when there's
  neither the local cloud nor Cognito Identity.

## Verified (2026-10-11)

- Floci (nightly 09-24-2026) answers S3 over HTTPS on 8443 with CORS once
  the bucket has rules, STS, and MQTT over `ws://localhost:4566/mqtt`:
  two of the app's MQTT clients, connecting with presigned `ws://` URLs,
  exchanged a message.
- The deployed local `ProfileFunction`, invoked with a verified email's
  claims, answered 200 twice with the same identity, the tier from rbacr's
  RC, the local bucket and new credentials, calling no Cognito; those
  credentials wrote and listed the identity's folder in the local bucket
  over HTTPS, and the bucket answered the browser's CORS preflight.
- The health line: ☁️ AWS ✅.
- Not checked from the command line: a Google sign-in in the browser and
  the app syncing through it.

## Known limitations

- **Nothing is enforced**: Floci checks neither the credentials nor IAM,
  so the bucket's premium-only rule and the per-identity folders aren't
  tested locally; free and premium behave as in the app, nothing more.
- **No Feedback & Help locally**: Floci's DynamoDB answers no CORS
  preflight, so the browser can't reach it; the build has no table.
- **Gone at each start**: Floci's memory storage loses the bucket's
  contents, the profiles and the devices whenever it restarts.
- **Phones still use production** (their builds call production's auth
  API), so they don't sync with the local web app.
