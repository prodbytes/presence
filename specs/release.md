# Release builds

[.github/workflows/release.yml](../.github/workflows/release.yml) builds the
app binaries with `make` and publishes them as a GitHub release.

- **Triggers:**
  - A pushed tag matching `*QA` or `*RC*` (e.g. `1.2.0-QA`, `1.2.0-RC1`)
    is released as a **prerelease** under that tag. `*RC*` tags are also
    deployed to https://rc.presence.nu01.com (see
    [Release candidates](deploy.md#release-candidates-rcpresencenu01com)).
  - A pushed tag matching `*GA` (e.g. `1.0.202609261530-GA`) is also
    deployed to https://presence.nu01.com by the Deploy workflow (see
    [Production deploy](deploy.md)). It's released
    as a full release, which GitHub marks as the latest.
  - **Manual dispatch** (Actions → Release → Run workflow) takes an
    optional `tag` and a `prerelease` switch (on by default). An empty tag
    uses the selected ref if it's a tag, or `manual-<run number>`. A tag
    that doesn't exist yet is created on the dispatched commit; one that
    exists must name the dispatched commit (dispatch from the tag). Turning
    `prerelease` off publishes a full release only when dispatched from
    `main` (or a tag) whose commit is on `main`; from any other ref it's
    published as a prerelease anyway, with a warning, so it can never
    become "latest".
  - **Pull requests** that change the workflow, the `Makefile`,
    `scripts/make.sh`, `scripts/deb.sh`, `packaging/`,
    `presence_streamer/`, `scripts/streamer.sh`,
    `scripts/dart-defines.sh`, `scripts/version.sh`,
    `presence_app/android/app/build.gradle.kts`,
    `presence_app/ios/Flutter/Release.xcconfig` or
    the version files run the builds only,
    without a release. They never get the signing secrets: they build the
    debug-signed APK and the unsigned iOS app, not the `.aab` or `.ipa`.
  - Tag names must be letters, digits, `.`, `_` and `-`.
- **Version:** the `prepare` job resolves one version for all the builds
  (see [Versioning](#versioning)). A tag that carries `X.Y.Z` (e.g.
  `1.0.202609261530-RC`) keeps its Z, and fails if its X.Y doesn't match the
  version files; any other run gets Z from the current time.
- **Builds:** one job per target, all with Flutter 3.47.5 (cloned at its
  tag, and checked to be the pinned commit `6a19cca5…`, `FLUTTER_COMMIT`,
  so a moved tag fails the build): `web` and `android` (JDK 17) on `ubuntu-latest`, `ios` on
  `macos-latest`, and `linux` (GTK build packages) twice, x64 on
  `ubuntu-22.04` and arm64 on `ubuntu-22.04-arm` (Flutter doesn't
  cross-compile Linux desktop). Each runs `make <target>`; the arm64 one
  runs `make deb`, which builds the bundle and packages it as the
  [Raspberry Pi camera](raspberry-pi.md) `.deb`.
  - Linux builds on 22.04 because the bundle needs at least the GLib and
    glibc it was built against. A 24.04 build (GLib 2.80) fails on
    Debian 12 / Raspberry Pi OS Bookworm (GLib 2.74) with
    `undefined symbol: g_once_init_enter_pointer`; a 22.04 one runs on
    Debian 12, Ubuntu 22.04 and anything newer.
- **Release name:** `presence-<tag>`, e.g. `presence-1.0.0-RC2` for the
  tag `1.0.0-RC2` (tags stay `X.Y.Z-KK`).
- **Release assets**, uploaded to a new release or replacing same-named
  assets on an existing one, with generated notes:
  - `presence-<tag>-web.zip`: the contents of `build/web/`.
  - `presence-<tag>-android.apk`: the release APK, signed with the
    upload key when it's set (see [Store signing](#store-signing)), else
    with the runner's debug key.
  - `presence-<tag>-android.aab`: the Android App Bundle for Google Play,
    signed with the upload key; only when the upload key is set.
  - `presence-<tag>-ios.ipa`: the App Store `.ipa`, when App Store signing
    is set; otherwise `presence-<tag>-ios-unsigned.zip`, the unsigned
    `Runner.app`.
  - `presence-<tag>-linux-x64.tar.gz` and
    `presence-<tag>-linux-arm64.tar.gz`: the Linux `bundle/` for each
    architecture (named from Flutter's `build/linux/<arch>/` folder).
  - `presence-<tag>-raspberrypi-arm64.deb`: the arm64 bundle as the
    [Raspberry Pi camera](raspberry-pi.md) package (the job prints its
    `dpkg-deb --info` and contents).
  - `presence-streamer-<tag>-raspberrypi-armhf.deb` and `-arm64.deb`, and
    `presence-streamer-<tag>-linux-armhf.tar.gz` and `-arm64.tar.gz`: the
    [streamer](streamer.md), for 32- and 64-bit Raspberry Pis. The
    `streamer` job (ubuntu-latest, Go from `presence_streamer/go.mod` with
    `actions/setup-go`) runs its unit tests and `make streamer`: Go
    cross-compiles both from one runner.
- **Settings:** the job writes a `.env` with only the Google client IDs,
  from the repository **variables** `GOOGLE_WEB_CLIENT_ID` and
  `GOOGLE_IOS_CLIENT_ID`. They're public identifiers that get compiled into
  the app anyway, so they aren't secrets; the web client's secret is never
  given to the workflow. The streamer job gets its device sign-in client from
  the variable `GOOGLE_DEVICE_CLIENT_ID` and the secret
  `GOOGLE_DEVICE_CLIENT_SECRET` (that kind of client's secret isn't
  confidential to Google: it ships in the binary), and its [live
  sync](live-sync.md) endpoint from the variable `IOT_ENDPOINT` (the
  account's public AWS IoT endpoint; without it the streamer's live sync is
  off unless set on the Pi).
- **Security:** actions are pinned to commit SHAs, Flutter to a commit and
  the SAM CLI to a version (1.165.0, in the deploy workflows); the
  workflow token is read-only except in the release job (`contents:
  write`); checkout doesn't keep credentials; inputs reach scripts only
  through environment variables.

## Store signing

The Release workflow signs the store builds when their secrets are set,
and skips them, with a notice in the run, when they aren't. Nothing is
signed on pull requests. The keys are decoded into the runner's temporary
folder, and removed at the end of the job, even after a failure.

### Google Play (Android)

- **Upload key:** Play App Signing holds the key that signs what users
  install; the workflow signs with the **upload key**, which Play checks.
  [scripts/android-upload-key.sh](../scripts/android-upload-key.sh)
  creates it with `keytool` (PKCS12, RSA 4096, alias `upload`, one
  password, valid ~27 years) by default in the private credentials clone
  next to the repo, at
  `../setec-astronomy/presence.nu01/env.local/android/upload-keystore.jks`
  (git-ignored there), or at `~/.config/presence/upload-keystore.jks`
  without that clone (it refuses a path inside the repo), and prints its SHA-1
  and SHA-256 fingerprints and the `gh secret set` commands below. Given
  an existing keystore, it only prints those. Keep the keystore and
  password backed up: losing them means asking Google to reset the
  upload key.
- **Gradle** ([android/app/build.gradle.kts](../presence_app/android/app/build.gradle.kts))
  signs release builds with the upload key from the environment
  (`ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`,
  `ANDROID_KEY_ALIAS`, default `upload`, and `ANDROID_KEY_PASSWORD`,
  default the keystore's), or else from
  `presence_app/android/key.properties` (`storeFile`, `storePassword`,
  `keyAlias`, `keyPassword`; never committed, like `*.jks`, `*.keystore`,
  `*.p12`, `*.p8` and `*.mobileprovision`). With neither, release APKs
  fall back to the debug key (`flutter run --release`,
  `scripts/android-install.sh`), but a **release App Bundle fails** ("A
  release App Bundle needs the upload key"), so a debug-signed bundle is
  never made. A named keystore that's missing, or has no password, fails
  every release build.
- **Builds:** `make appbundle` (`flutter build appbundle`, with the same
  version and settings as `make android`). The workflow runs `make
  android appbundle` when the key is set, and prints the bundle's signer.
- **Secrets** (Settings → Secrets and variables → Actions, or `gh`):

  | Name | What |
  | --- | --- |
  | `ANDROID_UPLOAD_KEYSTORE_BASE64` | the keystore, base64: `base64 < ../setec-astronomy/presence.nu01/env.local/android/upload-keystore.jks \| gh secret set ANDROID_UPLOAD_KEYSTORE_BASE64` |
  | `ANDROID_UPLOAD_KEYSTORE_PASSWORD` | its password: `gh secret set ANDROID_UPLOAD_KEYSTORE_PASSWORD` (asks for it) |
  | `ANDROID_UPLOAD_KEY_ALIAS` | optional, default `upload` |
  | `ANDROID_UPLOAD_KEY_PASSWORD` | optional, default the keystore's password |

- **In Play Console:** create the app (`com.nu01.presence`), turn on Play
  App Signing (let Google generate the app signing key), and upload the
  first `.aab` by hand; its upload key becomes the registered one. Then
  copy, from Setup → App signing, the **app signing key's** SHA-256 and
  SHA-1, which differ from the upload key's:
  - `/.well-known/assetlinks.json` on presence.nu01.com and
    rc.presence.nu01.com must list the app signing key's SHA-256, for
    [App Links](add-device.md) to open in the Play-installed app (and the
    upload key's, for side-loaded builds). The site doesn't serve that
    file yet: nothing in `presence_index/site/` or `scripts/deploy.sh`
    makes it. Its `sha256_cert_fingerprints` list takes several.
  - Google sign-in needs one Android OAuth client per signing key (a
    client takes one SHA-1): the app signing key's, or sign-in fails in
    the store build, and the upload key's, for side-loaded builds. Each in
    presence-492410, the web client's project (Google refuses an Android
    client in another project, error 28444); a package and SHA-1 can be in
    one client only, across all projects.

### App Store (iOS)

- **Signing:** with the secrets set, the iOS job imports the distribution
  certificate into a temporary keychain (random password, deleted after
  the job), installs the App Store provisioning profile (checked to be
  for `<team>.com.nu01.presence` and to list no devices), and writes
  `presence_app/ios/Flutter/Signing.xcconfig` (never committed), which
  `Release.xcconfig` includes if present: `CODE_SIGN_STYLE = Manual`, the
  team, `Apple Distribution` and the profile's UUID, for the Runner
  target only (not the Pods). Locally the file doesn't exist, so
  Flutter's automatic development signing is unchanged.
- **Builds:** `make ipa IOS_EXPORT_OPTIONS=<plist>` (`flutter build ipa
  --export-options-plist`). The workflow writes the `ExportOptions.plist`:
  method `app-store-connect`, the team, `signingStyle` manual,
  `Apple Distribution`, and `com.nu01.presence` mapped to the profile.
  Entitlements come from the Xcode project (e.g. Sign in with Apple's
  `Runner.entitlements`, when it's added): the App ID must have those
  capabilities before the profile is made, or the archive fails; remake
  the profile, and update its secret, after adding one.
- **Upload:** for a pushed `*RC*` or `*GA` tag (both checked to be on
  `main`), when the App Store Connect API key is set, the job uploads the
  `.ipa` with `xcrun altool --upload-app` (the key at
  `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`, removed after). It
  then shows in TestFlight; review and release stay manual. Without the
  key, the `.ipa` is only attached to the release. RC and GA tags pushed
  together can get the same build number (the build time in seconds) for
  the same version; App Store Connect then refuses the second upload as a
  duplicate (`ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE` with that build
  number as `previousBundleVersion`), and the job takes that as done,
  since the same build is already there. Any other upload error fails it.
- **Variables and secrets:**

  | Name | Kind | What |
  | --- | --- | --- |
  | `APPLE_TEAM_ID` | variable (or secret) | the 10-character team ID (Membership details; the development team seen locally is `LMX88986F3`): `gh variable set APPLE_TEAM_ID --body <team id>` |
  | `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | secret | the **Apple Distribution** certificate with its private key, exported from Keychain Access as `.p12`, base64: `base64 < dist.p12 \| gh secret set IOS_DISTRIBUTION_CERTIFICATE_BASE64` |
  | `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | secret | the `.p12`'s export password |
  | `IOS_APPSTORE_PROFILE_BASE64` | secret | an **App Store** provisioning profile for `com.nu01.presence` with that certificate, base64: `base64 < Presence_AppStore.mobileprovision \| gh secret set IOS_APPSTORE_PROFILE_BASE64` |
  | `APP_STORE_CONNECT_API_KEY_ID` | secret | optional (upload): the API key's ID |
  | `APP_STORE_CONNECT_API_ISSUER_ID` | secret | optional (upload): the issuer ID |
  | `APP_STORE_CONNECT_API_KEY_BASE64` | secret | optional (upload): the `AuthKey_<id>.p8`, base64 |

- **In Apple Developer and App Store Connect:** register the App ID
  `com.nu01.presence` (with Sign in with Apple once the app uses it);
  make an Apple Distribution certificate (Certificates → +, from a CSR
  made in Keychain Access) and export it with its key as `.p12`; make an
  App Store provisioning profile (Profiles → + → App Store Connect) for
  that App ID and certificate; create the app in App Store Connect; and,
  for uploads, an API key with the App Manager role (Users and Access →
  Integrations → App Store Connect API; the `.p8` downloads once).
- **Where the files live:** every signing credential (the distribution
  key, its CSR, `.cer` and `.p12` with its password, the App Store
  profile, the API key's `.p8`, the Android upload keystore and its
  password) is kept in the private credentials clone, under
  `../setec-astronomy/presence.nu01/env.local/` (`apple/`, `android/`),
  git-ignored there and listed in its README; never in this repo. The
  distribution key and CSR are made there with `openssl req -new -newkey
  rsa:2048 -nodes` rather than Keychain Access, so the `.p12` is built
  from them with `openssl pkcs12 -export`.
- The certificate and profile expire yearly; renew them and update the
  secrets.

## Release trust

What a tag can make CI do is checked in CI, not only by the scripts that
push tags:

- **On `main` only.** The Deploy and Deploy RC workflows, and the Release
  workflow for `*GA` and `*RC*` tags, check out full history
  (`fetch-depth: 0`) and refuse a tag whose commit isn't on `main` (`git
  merge-base --is-ancestor <commit> origin/main`), before any build or AWS
  access. `*QA` tags may be on any branch (always prereleases).
- **Names.** Deploy takes only `X.Y.Z-GA`; Deploy RC only `X.Y.Z-RC` or
  `X.Y.Z-RC<n>` (`^[0-9]+\.[0-9]+\.[0-9]+-RC[0-9]*$`), whether pushed or
  given as its manual `tag` input, which must also be an existing tag
  (checked out as `refs/tags/<tag>`, so a branch of that name can't stand
  in). A manual Deploy RC run without a tag deploys `main`'s commit; from
  another branch it's refused.
- **Latest.** Only a pushed `*GA` tag on `main`, or a manual run as above
  from `main`, publishes a full release (`--latest`); everything else is a
  prerelease (`--latest=false`).
- **Signed tags.** `scripts/tag-release.sh` creates **signed** annotated
  tags (`git tag --sign`, with the user's GPG or SSH signing key;
  `tag.gpgSign` makes plain `git tag` sign too). The Deploy workflow
  warns (doesn't fail) when GitHub can't verify the tag's signature, so a
  key GitHub doesn't know can't block a release; add the signing key to
  the GitHub account as a signing key.

### Recommended GitHub rulesets (not applied by this repository)

Set in Settings → Rules → Rulesets (they need a repository admin), so
only the maintainers can make a tag that deploys:

- **Release tags:** a tag ruleset targeting `*-GA`, `*-RC` and `*-RC*`
  (and `*GA`, `*RC*`, which the workflows trigger on): restrict
  creations, updates and deletions, with bypass only for the maintainers
  (or a "release" team). Rulesets can't require a tag's own signature
  ("require signed commits" checks commits), hence the CI check above.
- **`main`:** a branch ruleset: require pull requests (with the
  maintainers' approval), block force pushes and deletions, require the
  Release workflow's PR build where it runs.
- Optionally, **Actions → General**: require approval for workflows from
  outside collaborators, and keep `GITHUB_TOKEN` read-only by default.

**First release:** [1.0.0-RC1](https://github.com/prodbytes/presence/releases/tag/1.0.0-RC1),
from the tag pushed on `main` after the workflow was merged. All four assets
were checked: the web bundle has the web client ID and no secret; the APK is
`com.nu01.presence` 1.0.0 with a valid signature; `Runner.app` is arm64
with the iOS client ID and its URL scheme; the Linux bundle is x86-64.

## Tagging a release

Two scripts tag the current commit with the current version (Z = now) and
push the tag, which starts the workflow:

- [scripts/release-rc.sh](../scripts/release-rc.sh) tags `X.Y.Z-RC`
  → prerelease `presence-X.Y.Z-RC`.
- [scripts/release-ga.sh](../scripts/release-ga.sh) tags `X.Y.Z-GA`
  → latest release `presence-X.Y.Z-GA`.

Both run [scripts/tag-release.sh](../scripts/tag-release.sh), which refuses
when tracked files have uncommitted changes, when the commit isn't pushed,
when it isn't on `main` (both kinds; CI refuses them too, see [Release
trust](#release-trust)), or when the tag already exists (tags are unique
per minute). It **signs** the tag (`git tag --sign`) and stops if signing
fails.
`DRY_RUN=1 bash scripts/release-rc.sh` checks and prints the tag without
creating it. Each GA gets its own new Z, so it's a fresh build of the
commit, not the RC's binaries.

## Versioning

The app version is `X.Y.Z`, resolved by
[scripts/version.sh](../scripts/version.sh):

- **X** and **Y** come from [version.X.txt](../version.X.txt) and
  [version.Y.txt](../version.Y.txt) at the repo root (now `0` and `7`).
  Edit them to bump the major or minor version.
- **Z** is the build time as a UTC timestamp, `YYYYMMDDHHMM` (e.g.
  `1.0.202609261534`).
- The **build number** is the same instant in Unix seconds (e.g.
  `1790436872`): Android's `versionCode` and iOS's `CFBundleVersion`. It
  always increases, and fits Android's 2,100,000,000 limit until 2036.
- `VERSION_Z` and `BUILD_NUMBER` override them (e.g. `make web
  VERSION_Z=42`); all must be whole numbers. The Makefile fixes the build
  time once per `make` run, so every target in it shares a version.
- `make` passes them to Flutter as `--build-name` / `--build-number`,
  overriding `pubspec.yaml`'s `version`, which only applies to
  `flutter run`. They show in web's `version.json`, Android's
  `versionName`/`versionCode` and iOS's `CFBundleShortVersionString`/
  `CFBundleVersion`.
- `make` also compiles in `PRESENCE_VERSION` (`X.Y.Z`), which the Settings
  screen shows (see [Settings](settings.md)).

## Known limitations

- Until the upload key secrets are set, the APK is signed with the
  runner's throwaway debug key, which differs on every run: Google sign-in
  on Android won't accept it (the Android client is matched by the
  development Mac's debug-key SHA-1), it can't be installed over an
  earlier build without uninstalling first, and there's no `.aab`.
- Until the App Store secrets are set, the iOS app is unsigned, so it
  can't be installed on a device as is. The signed `.ipa` and the upload
  haven't run yet (no certificate or profile exists); only the generated
  `Signing.xcconfig` and `ExportOptions.plist` were checked (Xcode reads
  the signing settings for Release, not Debug).
- The marketing version's Z is a 12-digit timestamp
  (`0.7.202610161800`). App Store Connect takes it in
  `CFBundleShortVersionString`: build `0.6.202610151308` was accepted on
  2026-10-16.
- The build number (Unix seconds) outgrows Android's `versionCode` limit in
  2036.
