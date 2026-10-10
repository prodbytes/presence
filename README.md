# Presence

Presence helps you keep track of what happens in a private place you're
responsible for, such as your home, a shop or an office. It turns a phone,
tablet or laptop into an always-on camera. It shows the live feeds and
records clips, including the moments before you pressed Clip. It also
records automatically when the picture moves, and lets you tag the people and
pets in a clip. Signed-in users' clips and events sync to the cloud, so they
can be viewed from another device.

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/prodbytes/presence?machine=standardLinux32gb)
[![Open in Dev Containers](https://img.shields.io/static/v1?label=Dev%20Containers&message=Open&color=007ACC&logo=visualstudiocode)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/prodbytes/presence)

- Production: **https://presence.nu01.com**
- Release candidate: **https://rc.presence.nu01.com**
- Run the latest release on this machine:

  ```sh
  curl -fsSL https://sh.presence.nu01.com | sh
  ```

  On Linux x64 or arm64 it downloads and runs the native app (it needs
  `libgtk-3-0 libegl1 libgles2`); anywhere else, or if the native app
  can't run, it opens the web app. See [specs/install-script.md](specs/install-script.md);
  [presence_sh/](presence_sh) serves it.
- Make a Raspberry Pi a camera that starts at boot: the
  `presence-<tag>-raspberrypi-arm64.deb` package; see
  [Raspberry Pi](#raspberry-pi).

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

## Raspberry Pi

### As a camera (the .deb)

The `presence-<tag>-raspberrypi-arm64.deb` package turns a Raspberry Pi
into a Presence camera: it starts by itself at every boot, full screen,
and comes back if it crashes. Details: [specs/raspberry-pi.md](specs/raspberry-pi.md).

> [!IMPORTANT]
> **The camera runs as the web app, not the native Linux app.** The native
> Linux app has no camera layer (and no Google sign-in) yet, so it can't
> record. The kiosk opens https://presence.nu01.com/app/ in Chromium
> instead, which records video and audio like the web app anywhere else.

**What you need**

- A Raspberry Pi 4 or 5 (2 GB or more) with **Raspberry Pi OS (64-bit)**,
  Bookworm or newer. **Lite** (no desktop) is the simplest: the camera
  takes over the screen. On the desktop image, see step 3.
- A **USB webcam** (any UVC camera; most USB webcams are). A Raspberry Pi
  camera module (CSI) isn't verified: the kiosk runs Chromium under
  `libcamerify` for it (`sudo apt install libcamera-v4l2`), which may or
  may not work.
- A microphone for audio (many webcams have one).
- A screen is optional: without one it records on a virtual display. A
  mouse and keyboard (or touch screen) only for the first setup.
- A network connection: it loads the web app from presence.nu01.com.

**Install**

1. Download the `.deb` from the latest release on
   [GitHub Releases](https://github.com/prodbytes/presence/releases)
   (`presence-<tag>-raspberrypi-arm64.deb`; releases after this package
   was added have it) and install it with apt, which also installs what
   it needs (cage, Chromium, Xwayland, GTK):

   ```sh
   sudo apt update
   sudo apt install ./presence-<tag>-raspberrypi-arm64.deb
   ```

   Or let the install script download, verify and install the latest one:

   ```sh
   curl -fsSL https://sh.presence.nu01.com | PRESENCE_KIOSK=1 sh
   ```

2. On Raspberry Pi OS Lite the camera starts right away on the screen
   (tty1), and at every boot after that.
3. On the desktop image the desktop keeps the screen. To boot into the
   camera instead (this turns the desktop off at boot):

   ```sh
   sudo presence-kiosk enable
   sudo reboot
   ```

**First setup** (once, with a mouse and keyboard)

1. Tap **I agree** on the recording consent screen.
2. Sign in with Google from the app bar, with the same account as your
   other devices: that's what makes the Pi one of your devices (the
   **Add a device** link is the same sign-in, checked against the link;
   on the Pi just sign in). The Google session stays in the kiosk's
   browser profile (`/var/lib/presence`), so after a reboot or restart the
   app signs back in by itself (Google's automatic sign-in), like the web
   app does in any browser.

Then unplug the keyboard and mouse: it runs without them.

**Start, stop, logs**

```sh
sudo systemctl restart presence-kiosk    # restart (also: sudo presence-kiosk restart)
sudo systemctl stop presence-kiosk       # stop until the next boot
sudo systemctl start presence-kiosk      # start again
systemctl status presence-kiosk          # is it running?
journalctl -u presence-kiosk -f          # its log
sudo presence-kiosk disable              # don't start at boot (and give the screen back to the desktop)
sudo presence-kiosk enable               # start at boot again
```

Settings are in `/etc/default/presence` (which URL to open, the camera
module wrapper, extra Chromium flags); restart after editing it.

**Uninstall**

```sh
sudo apt remove presence   # stops it and gives the screen back; keeps settings and sign-in
sudo apt purge presence    # also deletes the settings and /var/lib/presence (sign-in, clips not yet synced)
```

### From the desktop (native app)

The install script also runs the native Linux app on a Raspberry Pi
desktop, without installing anything system-wide. It has **no camera
support yet**, so it's only useful to look at events and clips. You need
Raspberry Pi OS (64-bit), Bookworm or newer, with the desktop; the 32-bit
OS has no native build, so the script opens the web app there instead.

1. Open a terminal on the Pi's desktop. The app needs a display, so over
   SSH, run it from the desktop session instead.
2. Install the libraries the app needs (the desktop image usually has most
   of them already):

   ```sh
   sudo apt update
   sudo apt install -y curl libgtk-3-0 libegl1 libgles2
   ```

3. Download and run the latest release:

   ```sh
   curl -fsSL https://sh.presence.nu01.com | sh
   ```

   The first run downloads the release to
   `~/.local/share/presence/<release>/`; later runs of the same release
   start straight away. Run the same command again to start Presence, and to
   update it when a new release is out.

If the app can't start, the script says why (a missing library, or no
display), then opens https://presence.nu01.com in the browser instead.

## Technology

| Part | Technology | Main libraries and frameworks |
|---|---|---|
| App ([presence_app/](presence_app)) | [Flutter](https://flutter.dev) (Dart): web, Android, iOS and Linux from one codebase | `web` (browser camera and recording APIs), native recording layers (Camera2 on Android, AVFoundation on iOS), `video_player`, `idb_shim` (IndexedDB storage), `google_sign_in`, `http`, `crypto` |
| Auth API ([presence_api_auth/](presence_api_auth)) | Java 25 on AWS Lambda, deployed with [AWS SAM](https://aws.amazon.com/serverless/sam/) | AWS Lambda Java core/events, AWS SDK v2 (DynamoDB), JUnit 5; built with Maven |
| Health check ([presence_health/](presence_health)) | Java 25 on AWS Lambda (`GET /health`), deployed with AWS SAM | AWS Lambda Java core/events, AWS SDK v2 (DynamoDB, S3, Cognito Identity), JUnit 5; built with Maven |
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

## Before you start

Do these once, before you start the dev environment or deploy. Both are
optional for local development, but know what you give up:

> [!WARNING]
> **Without OIDC** (no `GOOGLE_WEB_CLIENT_ID`), authentication is disabled:
> the system runs in [DEV mode](specs/execution-mode.md), nobody signs in,
> and the anonymous user gets every role, so anyone who can open the app
> has full access. Use it only on your own machine; deploys refuse to run
> without it.
>
> **Without the AWS settings** (`COGNITO_IDENTITY_POOL_ID` and
> `USER_DATA_BUCKET`), no events or clips are shipped to S3: everything
> stays on the device. Without AWS access you also can't deploy.

The cameras and clips work either way. Settings shows which of these are
set, under the version: `🔌 API · ☁️ AWS · 🔑 OIDC`.

### 1. Get the code and tools

1. Install [Devbox](https://www.jetify.com/devbox/docs/installing_devbox/)
   and Docker.
2. Clone the repo, create your `.env` and enter the environment (the first
   run takes a few minutes):

   ```bash
   git clone git@github.com:prodbytes/presence.git
   cd presence
   cp .env.example .env
   devbox shell
   ```

### 2. Create the Google OAuth clients

1. Sign in to the [Google Cloud Console](https://console.cloud.google.com/)
   with a Google account and create a project (or pick one).
2. Under **APIs & Services → OAuth consent screen**, set up the consent
   screen (External, with the app's name and your email). While it's in
   testing, add the accounts that will sign in as test users.
3. Under **APIs & Services → Credentials → Create credentials → OAuth
   client ID**, create:
   - a **Web application** client with Authorized JavaScript origins
     `http://localhost:8080` and `https://local.presence.nu01.com:8443`
     (add your deployed domains later). It needs no redirect URI. Copy its
     ID into `GOOGLE_WEB_CLIENT_ID` and its secret into
     `GOOGLE_WEB_CLIENT_SECRET`;
   - an **iOS** client with bundle ID `com.nu01.presence`, for
     `GOOGLE_IOS_CLIENT_ID`;
   - an **Android** client with package `com.nu01.presence` and your
     signing key's SHA-1 (`keytool -list -v -alias androiddebugkey
     -keystore ~/.android/debug.keystore -storepass android` for the debug
     key), for `GOOGLE_ANDROID_CLIENT_ID`.

### 3. Set up AWS access

1. Create an [AWS account](https://aws.amazon.com/) if you don't have one,
   and an IAM Identity Center user or access key that can create
   CloudFormation stacks, S3 buckets, Cognito identity pools and IAM roles.
2. Configure the CLI (it's in the devbox shell from step 1), then check it
   works:

   ```bash
   aws configure sso          # or: aws configure, with an access key
   aws sts get-caller-identity
   ```

3. Create the bucket and identity pool from
   [presence_infra/](presence_infra), with your web client ID:

   ```bash
   GOOGLE_WEB_CLIENT_ID="$(sed -n 's/^GOOGLE_WEB_CLIENT_ID=//p' .env)"
   aws cloudformation deploy --region us-east-1 \
     --stack-name presence-user-data \
     --template-file presence_infra/user-data.yaml
   aws cloudformation deploy --region us-east-1 \
     --stack-name presence-identity \
     --template-file presence_infra/identity.yaml --capabilities CAPABILITY_IAM \
     --parameter-overrides "GoogleWebClientId=$GOOGLE_WEB_CLIENT_ID"
   ```

4. Copy the outputs into `.env` as `COGNITO_IDENTITY_POOL_ID` and
   `USER_DATA_BUCKET`:

   ```bash
   aws cloudformation describe-stacks --region us-east-1 --stack-name presence-identity \
     --query "Stacks[0].Outputs[?OutputKey=='IdentityPoolId'].OutputValue" --output text
   aws cloudformation describe-stacks --region us-east-1 --stack-name presence-user-data \
     --query "Stacks[0].Outputs[?OutputKey=='UserDataBucketName'].OutputValue" --output text
   ```

5. If you'll deploy to AWS, find your domain's zone ID for `HOSTED_ZONE_ID` (the
   part after `/hostedzone/`):

   ```bash
   aws route53 list-hosted-zones --query "HostedZones[].[Name,Id]" --output text
   ```

### 4. Check your settings

The settings live in `.env` (git-ignored; [.env.example](.env.example)
lists the names). Only `GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`,
`AWS_REGION`, `COGNITO_IDENTITY_POOL_ID` and `USER_DATA_BUCKET` reach the
app ([scripts/dart-defines.sh](scripts/dart-defines.sh)). They're compiled
in, so never add a secret to that list.

| Variable | Purpose | Where it comes from |
|---|---|---|
| `GOOGLE_WEB_CLIENT_ID` | Google sign-in. Every platform's ID token is issued for this client, and Cognito and the auth API trust it | Google Cloud: the Web application client |
| `GOOGLE_IOS_CLIENT_ID` | Google sign-in on iOS (its reversed ID is the app's URL scheme) | Google Cloud: the iOS client |
| `GOOGLE_ANDROID_CLIENT_ID` | Reference only. Google matches Android by package name and signing key, so the app doesn't use it | Google Cloud: the Android client |
| `GOOGLE_WEB_CLIENT_SECRET` | Not used by the app. It's kept for a future backend and is never passed to Flutter | Google Cloud: the Web application client |
| `AWS_REGION` | The region of the cloud-sync resources (`us-east-1`) | Your choice |
| `COGNITO_IDENTITY_POOL_ID` | Cloud sync: trades the Google ID token for temporary AWS credentials | Output `IdentityPoolId` of the `presence-identity` stack |
| `USER_DATA_BUCKET` | Cloud sync: the S3 bucket for clips and events | Output `UserDataBucketName` of the `presence-user-data` stack |
| `HOSTED_ZONE_ID` | Deploys only: the Route 53 zone of the site's domain | Route 53 |

## Run it locally with devbox

After [Before you start](#before-you-start), from the repo inside
`devbox shell`:

```bash
devbox run mkcert -install   # once, so browsers trust the local HTTPS certificate
devbox services up           # add --pcflags "--tui=false" when not in a terminal
```

That starts these services, wired up in
[process-compose.yaml](process-compose.yaml):

| URL | What |
|---|---|
| http://localhost:8080/app/ | The Flutter app in web mode ([scripts/flutter-web.sh](scripts/flutter-web.sh)). Press `r` in its terminal to hot reload |
| http://localhost:8081 | The site index ([presence_index/](presence_index)), which redirects to `/app/` |
| http://presence.localhost:4566/ | Floci, the local CloudFront, in front of the index, the app and the API |
| https://local.presence.nu01.com:8443/ | The same over HTTPS, a public name for 127.0.0.1 that works as a Google OAuth origin |

A `health-check` monitor logs one line every 15 s (set
`HEALTH_CHECK_INTERVAL` to change it): the time, then each check as its
emoji, a short label and ✅ ok / ❌ failed / ⚪ not set. The checks are 🏠
Index, 🌐 Web app, 🚚 CDN, 🔒 HTTPS, 🔌 auth API, then the API's settings
🔑 OIDC, ☁️ AWS and 👮 RBACR, and last 💎 RBACR svc (rbacr's `/health`). Without `.env` it looks
like this:

```
2026-10-10 12:35:54 🏠 Index ✅ · 🌐 Web ✅ · 🚚 CDN ✅ · 🔒 HTTPS ✅ · 🔌 API ✅ · 🔑 OIDC ⚪ · ☁️ AWS ⚪ · 👮 RBACR ⚪ · 💎 RBACR svc ✅
```

Stop everything with `devbox services stop`. To run only the app, use
`devbox run web` (set `FLUTTER_WEB_PORT` to change the port).

To run it on an Android phone attached by USB, turn on USB debugging on
the phone (Settings > Developer options), allow this computer when asked,
and run `devbox run android` (or `bash scripts/flutter-android.sh`). Extra
arguments go to `flutter run`, e.g. `--release`. With several phones
attached, pick one with `ANDROID_SERIAL=<serial>` from `adb devices`. The
phone uses the production API, so sign in with Google; add
`--dart-define=API_BASE_URL=<url>` to point it elsewhere. To read the
app's log on the phone (its messages, Google sign-in errors and crashes,
without the rest of Android's log), run `devbox run android-log`.

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

1. Click **Open in GitHub Codespaces** above; it selects a 4-core machine
   (16 GB RAM), the smallest that runs Flutter, Floci and the Java Lambdas
   together. Or, on the repo page, choose **Code → Codespaces → … → New with
   options** and pick **4-core**.
2. Wait for the container to build and set up. Its `postCreateCommand`
   ([post-create.sh](.devcontainer/post-create.sh)) downloads the locked
   tools (about 3.5 GB) and runs `devbox install` with the codespace's
   `GITHUB_TOKEN`, so Nix isn't rate-limited by GitHub. That takes several
   minutes the first time; after that the environment starts instantly.
   If it fails, the codespace still opens: the creation log's last lines
   say which step failed and how much disk is left, and
   `bash .devcontainer/post-create.sh` runs it again.
3. Create `.env` from [.env.example](.env.example) with the values from
   [Before you start](#before-you-start) (steps 2 to 4; the tools are
   already installed) if you need sign-in or cloud sync. Codespaces can provide the values as
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

## Deploy to Floci

[Floci](https://floci.io/) is a local AWS emulator. `devbox services up`
deploys into it on every start (process `4-floci`,
[presence_floci/](presence_floci)), so sign-in, profiles and account
linking work without an AWS account (roles, vouchers and maintenance
mode come from rbacr's RC, which the app asks directly):

- the **auth API** ([presence_api_auth/](presence_api_auth)) as the stack
  `presence-local-auth-api`: its Lambdas (run as `presence-lambda-*`
  Docker containers), DynamoDB tables and HTTP API;
- a **CloudFront distribution** routing `/app*` to the Flutter dev server,
  `/api/*` to the auth API and everything else to the index.

To deploy:

1. Create the Google OAuth clients and put `GOOGLE_WEB_CLIENT_ID` in
   `.env` ([Before you start](#before-you-start), step 2), or the auth API
   is skipped and signed-in users see only sign-up.
2. Start the services and wait for `4-floci` to be ready. The first run
   builds the API and pulls the Lambda image, which takes a few minutes:

   ```bash
   devbox services up
   ```

3. Open https://local.presence.nu01.com:8443/app/, the local origin
   registered with the Google web client.

Storage is in memory, so each start is a fresh deploy with empty tables.
To redeploy after changing the auth API, restart the process; it rebuilds
only when `presence_api_auth` changed:

```bash
devbox services restart 4-floci
```

To look inside, point the AWS CLI at Floci with dummy credentials:

```bash
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-east-1
aws --endpoint-url http://localhost:4566 cloudformation describe-stacks \
  --stack-name presence-local-auth-api --query "Stacks[0].StackStatus"
aws --endpoint-url http://localhost:4566 cloudfront list-distributions \
  --query "DistributionList.Items[].Aliases.Items"
```

Cloud sync isn't emulated: it still uses the AWS bucket and identity pool
from `.env`.

## Deploy to AWS

First complete [Before you start](#before-you-start): the deploy needs the
Google web client ID and AWS credentials, and a deploy to your own account
needs `HOSTED_ZONE_ID`.

Everything is deployed by [scripts/deploy.sh](scripts/deploy.sh) into
`us-east-1`. It first checks that the stage's permissions boundary and SAM
artifact bucket exist (both from the `presence-github-deploy` stack, see
below), then deploys the stacks in this order:

1. `presence-user-data`: the S3 bucket for users' clips and events.
   Objects expire after 90 days.
2. `presence-identity`: the Cognito identity pool, and live sync's IoT
   policy.
3. The auth API with SAM (`presence-auth-api`), uploaded to the stage's
   own artifact bucket, then its health check (`presence-health`,
   `GET /health`), which imports the auth API's table names.
4. `presence-web`: the certificate, the bucket, CloudFront (with its
   security headers) and the DNS records, and the `/health` check.

Every IAM role these stacks create carries the stage's permissions
boundary. It then uploads the web build, invalidates the cache and
smoke-tests the live site; if anything fails, it prints the version that
was live before and how to redeploy it. With `STAGE=rc` it deploys the
release candidate's own separate copies (`presence-rc-*`). The Deploy
workflow then deploys the install URL (`scripts/deploy-sh.sh`).

**One-time setup** (an administrator): deploy
[presence_infra/github-deploy.yaml](presence_infra/github-deploy.yaml):
the GitHub OIDC provider and roles, and per stage the deploy policies,
the permissions boundary and the SAM artifact bucket. Then set the
repository variables `AWS_DEPLOY_ROLE_ARN`, `AWS_DEPLOY_RC_ROLE_ARN`,
`HOSTED_ZONE_ID` and `GOOGLE_WEB_CLIENT_ID`. Finally, add the site origins
to the Google OAuth client. The exact commands are in
[presence_infra/README.md](presence_infra/README.md). The workflows hold no
AWS keys; they exchange GitHub's OIDC token for those roles, which trust
this repository's tags in both of GitHub's subject forms
(`repo:prodbytes/presence:…` and the immutable
`repo:prodbytes@<owner id>/presence@<repo id>:…`).

**Releasing:**

| Command | Tag | Deploys to |
|---|---|---|
| `bash scripts/release-rc.sh` | `X.Y.Z-RC` | **https://rc.presence.nu01.com** ([Deploy RC workflow](.github/workflows/deploy-rc.yml)) |
| `bash scripts/release-ga.sh` | `X.Y.Z-GA` | **https://presence.nu01.com** ([Deploy workflow](.github/workflows/deploy.yml)) |

Every pushed `X.Y.Z-RC` tag is deployed automatically to
https://rc.presence.nu01.com, and every pushed `X.Y.Z-GA` tag to
production, https://presence.nu01.com, if its commit is on `main` (the
workflows check). The scripts sign the tags. The Deploy RC workflow can
also be run by hand, from `main`, with an optional RC tag. Both kinds of
tag also publish the binaries through the
[Release workflow](.github/workflows/release.yml).

To deploy into your own AWS account, run the script by hand with admin
credentials, inside devbox. Your `.env` must have `HOSTED_ZONE_ID` set to a
Route 53 zone you control, and the `presence-github-deploy` stack must be
deployed first (it holds the boundaries and SAM buckets the script uses).
The domain names are set in [presence_infra/](presence_infra).

```bash
TAG=0.1.0-GA bash scripts/deploy.sh             # production stacks
STAGE=rc TAG=0.1.0-RC bash scripts/deploy.sh    # release-candidate stacks
```

## Contributing

Contributions are most welcome: bug reports, ideas, docs and code. To
contribute:

1. Fork the repo, or create a branch from an up-to-date `main`.
2. Make one change per pull request, with its tests. Run `flutter test` in
   `presence_app/` and `mvn test` in `presence_api_auth/AuthFunction/`
   and `presence_health/HealthFunction/`.
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
- [presence_health/README.md](presence_health/README.md): the `/health`
  check.
- [presence_floci/README.md](presence_floci/README.md): the local CDN.

### How the dev container is built

The [Containerfile](.devcontainer/Containerfile) starts from Microsoft's
`ubuntu-24.04` devcontainer base image and adds Devbox on top:

1. Devbox is installed as root. Everything else then runs as the `vscode`
   user, so the Nix store's owner matches the container's `remoteUser`.
2. Nix is installed in single-user mode (`--no-daemon`). Containers have no
   systemd, so the multi-user Nix daemon can't run. Devbox and Nix are
   pinned: Devbox's release binary and the Nix installer are each checked
   against their published SHA-256.
3. The image stops there; it doesn't fill the Nix store. On container
   start, `postCreateCommand` downloads the locked store paths straight from
   `cache.nixos.org` (no GitHub API calls), quietly so the creation log
   stays readable, then runs `devbox install`, which finds them cached. A
   failure reports the step and the free disk space.

## License

[MIT](LICENSE) © 2026 ProdBytes
