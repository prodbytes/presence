# Presence

Presence helps you keep track of what happens in a private place you're
responsible for, such as your home, a shop or an office. It turns a phone,
tablet or laptop into an always-on camera. It shows the live feeds and
records clips, including the moments before you pressed Clip. It also
records automatically when the picture moves, and lets you tag the people and
pets in a clip. Signed-in users' clips and events sync to the cloud, so they
can be viewed from another device.

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/prodbytes/presence)
[![Open in Dev Containers](https://img.shields.io/static/v1?label=Dev%20Containers&message=Open&color=007ACC&logo=visualstudiocode)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/prodbytes/presence)

- Production: **https://presence.nu01.com**
- Release candidate: **https://rc.presence.nu01.com**

> [!IMPORTANT]
> **Make sure you're allowed to record.** Presence records video *and
> audio*. Laws on recording people vary by country, state and city. They
> often cover where cameras may point, whether people must be told or give
> consent, whether audio may be recorded at all, and how long footage may be
> kept. Before you use Presence, check that local law allows you to record in
> the place where you set it up. Only record places you have the right to
> monitor, and tell the people who may be recorded when the law requires it.
> You are responsible for how you use it. The software comes with no
> warranty ([LICENSE](LICENSE)).

## Technology

| Part | Technology | Main libraries and frameworks |
|---|---|---|
| App ([presence_app/](presence_app)) | [Flutter](https://flutter.dev) (Dart): web, Android, iOS and Linux from one codebase | `web` (browser camera and recording APIs), native recording layers (Camera2 on Android, AVFoundation on iOS), `video_player`, `idb_shim` (IndexedDB storage), `google_sign_in`, `http`, `crypto` |
| Auth API ([presence_api_auth/](presence_api_auth)) | Java 25 on AWS Lambda, deployed with [AWS SAM](https://aws.amazon.com/serverless/sam/) | AWS Lambda Java core/events, AWS SDK v2 (DynamoDB), JUnit 5; built with Maven |
| Infrastructure ([presence_infra/](presence_infra)) | AWS CloudFormation | CloudFront, S3, API Gateway (HTTP API), Cognito identity pools, DynamoDB, ACM, Route 53 |
| Local cloud ([presence_floci/](presence_floci)) | [Floci](https://floci.io/), a local AWS emulator, in Docker | A local CloudFront in front of the app, the index page and the API |
| Dev environment | [Devbox](https://www.jetify.com/devbox) (Nix) in a [Dev Container](https://containers.dev/) | process-compose for the services, GitHub Actions for CI/CD |

Sign-in uses Google. Its token gets the user's roles from the auth API, and
an AWS identity from Cognito, which can read and write only that user's own
data in S3.

The toolchain is pinned in [devbox.json](devbox.json) and locked in
[devbox.lock](devbox.lock):

| Tool | Version |
|------|---------|
| GraalVM CE | 25.2.4 (JDK 25) |
| Node.js | 26.x |
| Python | 3.14.x |
| PostgreSQL | 17.x |
| Flutter | 3.47.x |
| AWS SAM CLI | 1.165.x |
| Maven | 3.9.x |
| AWS CLI | 2.35.x |
| GNU Make, curl | 4.4.x, 8.17.x |

Docker isn't part of devbox. The services need a running Docker daemon
(Docker Desktop on macOS, or docker-in-docker in the dev container) and the
Docker CLI with the `compose` plugin.

## Run it locally with devbox

1. Install [Devbox](https://www.jetify.com/devbox/docs/installing_devbox/)
   and Docker.
2. Clone the repo and add your settings:

   ```bash
   git clone git@github.com:prodbytes/presence.git
   cd presence
   cp .env.example .env    # then fill in the values you need
   ```

   Maintainers keep the real settings (`.env`, `env.local/`) in the private
   [setec-astronomy](https://github.com/prodbytes/setec-astronomy) repo,
   under `presence.nu01/`. To use them, clone it next to this repo and link
   them in:

   ```bash
   git clone https://github.com/prodbytes/setec-astronomy.git ../setec-astronomy
   bash scripts/link-private.sh
   ```

   Without a Google client ID, sign-in is off. Without the Cognito and bucket
   settings, cloud sync is off. The cameras and clips still work.
3. Start everything:

   ```bash
   devbox shell            # enter the environment (the first run takes a few minutes)
   devbox run mkcert -install   # once, so browsers trust the local HTTPS certificate
   devbox services up      # add --pcflags "--tui=false" when not in a terminal
   ```

That starts these services, wired up in
[process-compose.yaml](process-compose.yaml):

| URL | What |
|---|---|
| http://localhost:8080/app/ | The Flutter app in web mode ([scripts/flutter-web.sh](scripts/flutter-web.sh)). Press `r` in its terminal to hot reload |
| http://localhost:8081 | The site index ([presence_index/](presence_index)), which redirects to `/app/` |
| http://presence.localhost:4566/ | Floci, the local CloudFront, in front of the index, the app and the API |
| https://local.presence.nu01.com:8443/ | The same over HTTPS, a public name for 127.0.0.1 that works as a Google OAuth origin |

A `health-check` monitor logs one status line per check (every 15 s; set
`HEALTH_CHECK_INTERVAL` to change it):

```
2026-07-09 20:02:10 🏠 index ✅ 🌐 web ✅ ☁️ cdn ✅ 🔒 https ✅
```

Stop everything with `devbox services stop`. To run only the app, use
`devbox run web` (set `FLUTTER_WEB_PORT` to change the port).

### Building the binaries

The [Makefile](Makefile) builds release binaries through
[scripts/make.sh](scripts/make.sh), with the settings from `.env`:

```bash
make            # every platform this host can build
make web        # presence_app/build/web/
make android    # presence_app/build/app/outputs/flutter-apk/app-release.apk
make ios        # presence_app/build/ios/iphoneos/Runner.app (macOS, unsigned)
make linux      # presence_app/build/linux/<arch>/release/bundle/ (Linux only)
make clean
```

Pass `MODE=profile` or `MODE=debug` for other build modes, and
`IOS_CODESIGN=1` to sign the iOS build (this needs a signing team in Xcode).

## Run it on GitHub Codespaces

1. Click **Open in GitHub Codespaces** above, or, on the repo page, choose
   **Code → Codespaces → Create codespace on main**.
2. Wait for the container to build. It needs a 4-core, 16 GB machine.
   Its `postCreateCommand` ([post-create.sh](.devcontainer/post-create.sh))
   runs `devbox install` with the codespace's `GITHUB_TOKEN`, so Nix isn't
   rate-limited by GitHub. The first run evaluates nixpkgs, which takes a
   few minutes; after that the environment starts instantly.
3. Create `.env` from [.env.example](.env.example) if you need sign-in or
   cloud sync. Codespaces can provide the values as
   [Codespaces secrets](https://docs.github.com/en/codespaces/managing-your-codespaces/managing-your-account-specific-secrets-for-github-codespaces).
4. In the terminal:

   ```bash
   devbox services up --pcflags "--tui=false"
   ```

5. Open the forwarded port **8080** from the **Ports** tab and go to `/app/`.
   The app uses Flutter's `web-server` device, so no browser is needed inside
   the container.

The same dev container also works locally in VS Code (the **Dev
Containers** badge above, or **Reopen in Container**). It ships the
[docker-in-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-in-docker),
so Floci and `docker ps` work inside it. Outside Codespaces, export
`GITHUB_TOKEN` (for example `export GITHUB_TOKEN=$(gh auth token)`) before
opening it if `devbox install` fails with HTTP 403.

> Google sign-in only works from origins registered on the OAuth client, so
> it won't work on a Codespaces URL unless you add that origin to your own
> client.

## Deploy to AWS

Everything is deployed by [scripts/deploy.sh](scripts/deploy.sh) into
`us-east-1`. It deploys the stacks in this order:

1. `presence-user-data`: the S3 bucket for users' clips and events.
   Objects expire after 90 days.
2. `presence-identity`: the Cognito identity pool.
3. The auth API with SAM (`presence-auth-api`).
4. `presence-web`: the certificate, the bucket, CloudFront and the DNS
   records.

It then uploads the web build, invalidates the cache and smoke-tests the
live site. With `STAGE=rc` it deploys the release candidate's own separate
copies (`presence-rc-*`).

**One-time setup** (an administrator, once): deploy the GitHub OIDC roles
from [presence_infra/github-deploy.yaml](presence_infra/github-deploy.yaml).
Then set the repository variables `AWS_DEPLOY_ROLE_ARN`,
`AWS_DEPLOY_RC_ROLE_ARN`, `HOSTED_ZONE_ID` and `GOOGLE_WEB_CLIENT_ID`. Finally,
add the site origins to the Google OAuth client. The exact commands are in
[presence_infra/README.md](presence_infra/README.md). The workflows hold no
AWS keys; they exchange GitHub's OIDC token for those roles.

**Releasing:**

| Command | Tag | Deploys to |
|---|---|---|
| `bash scripts/release-rc.sh` | `X.Y.Z-RC` | **https://rc.presence.nu01.com** ([Deploy RC workflow](.github/workflows/deploy-rc.yml)) |
| `bash scripts/release-ga.sh` | `X.Y.Z-GA` | **https://presence.nu01.com** ([Deploy workflow](.github/workflows/deploy.yml)) |

Every pushed tag that contains `RC` is deployed automatically to
https://rc.presence.nu01.com, and every pushed tag ending in `GA` is
deployed automatically to production, https://presence.nu01.com. The Deploy RC workflow can also be run by hand,
with an optional tag. Both kinds of tag also publish the binaries through the
[Release workflow](.github/workflows/release.yml).

To deploy into your own AWS account, run the script by hand with admin
credentials, inside devbox. Your `.env` must have `HOSTED_ZONE_ID` set to a
Route 53 zone you control. The domain names are set in
[presence_infra/](presence_infra).

```bash
TAG=0.1.0-GA bash scripts/deploy.sh             # production stacks
STAGE=rc TAG=0.1.0-RC bash scripts/deploy.sh    # release-candidate stacks
```

## Contributing

Contributions are most welcome: bug reports, ideas, docs and code. To
contribute:

1. Fork the repo, or create a branch from an up-to-date `main`.
2. Make one change per pull request, with its tests. Run `flutter test` in
   `presence_app/` and `mvn test` in `presence_api_auth/AuthFunction/`.
3. Update the matching feature spec in [specs/](specs/) and add an entry to
   [specs/requests.md](specs/requests.md).
4. Open a pull request against `main`.

You don't need to deploy anything yourself. GitHub Actions builds and deploys
merged changes automatically: the next `RC` tag puts them on
https://rc.presence.nu01.com for testing, and a `GA` tag ships them to
https://presence.nu01.com.

## Learn more

- [specs/](specs/README.md): the specification of every feature.
- [presence_infra/README.md](presence_infra/README.md): the AWS
  infrastructure.
- [presence_api_auth/README.md](presence_api_auth/README.md): the auth API.
- [presence_floci/README.md](presence_floci/README.md): the local CDN.

### How the dev container is built

The [Containerfile](.devcontainer/Containerfile) starts from Microsoft's
`ubuntu-24.04` devcontainer base image and adds Devbox on top:

1. Devbox is installed as root. Everything else then runs as the `vscode`
   user, so the Nix store's owner matches the container's `remoteUser`.
2. Nix is installed in single-user mode (`--no-daemon`). Containers have no
   systemd, so the multi-user Nix daemon can't run. Devbox and Nix are
   pinned, and the Nix installer is checked against its published hash.
3. At build time, the locked store paths are downloaded straight from
   `cache.nixos.org` to fill `/nix/store` in advance. This makes no GitHub
   API calls, so builds don't hit unauthenticated rate limits.
4. On container start, `postCreateCommand` runs `devbox install`, which
   finds the large downloads already cached.

## License

[MIT](LICENSE) © 2026 ProdBytes
