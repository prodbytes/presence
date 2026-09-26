# Release builds

[.github/workflows/release.yml](../.github/workflows/release.yml) builds the
app binaries with `make` and publishes them as a GitHub release.

- **Triggers:**
  - A pushed tag matching `*QA` or `*RC*` (e.g. `1.2.0-QA`, `1.2.0-RC1`)
    is released as a **prerelease** under that tag.
  - A pushed tag matching `*GA` (e.g. `1.0.202609261530-GA`) is released
    as a full release, which GitHub marks as the latest.
  - **Manual dispatch** (Actions → Release → Run workflow) takes an
    optional `tag` and a `prerelease` switch (on by default). An empty tag
    uses the selected ref if it's a tag, or `manual-<run number>`. A tag
    that doesn't exist yet is created on the dispatched commit.
  - **Pull requests** that change the workflow, the `Makefile`,
    `scripts/make.sh`, `scripts/dart-defines.sh`, `scripts/version.sh` or
    the version files run the builds only,
    without a release.
  - Tag names must be letters, digits, `.`, `_` and `-`.
- **Version:** the `prepare` job resolves one version for all four builds
  (see [Versioning](#versioning)). A tag that carries `X.Y.Z` (e.g.
  `1.0.202609261530-RC`) keeps its Z, and fails if its X.Y doesn't match the
  version files; any other run gets Z from the current time.
- **Builds:** one job per target, all with Flutter 3.47.5 (cloned at its
  tag): `web`, `android` (JDK 17) and `linux` (GTK build packages) on
  `ubuntu-latest`, and `ios` on `macos-latest`. Each runs `make <target>`.
- **Release name:** `presence-<tag>`, e.g. `presence-1.0.0-RC2` for the
  tag `1.0.0-RC2` (tags stay `X.Y.Z-KK`).
- **Release assets**, uploaded to a new release or replacing same-named
  assets on an existing one, with generated notes:
  - `presence-<tag>-web.zip`: the contents of `build/web/`.
  - `presence-<tag>-android.apk`: the release APK.
  - `presence-<tag>-ios-unsigned.zip`: the unsigned `Runner.app`.
  - `presence-<tag>-linux-x64.tar.gz`: the Linux `bundle/`.
- **Settings:** the job writes a `.env` with only the Google client IDs,
  from the repository **variables** `GOOGLE_WEB_CLIENT_ID` and
  `GOOGLE_IOS_CLIENT_ID`. They're public identifiers that get compiled into
  the app anyway, so they aren't secrets; the client secret is never given
  to the workflow.
- **Security:** actions are pinned to commit SHAs; the workflow token is
  read-only except in the release job (`contents: write`); checkout doesn't
  keep credentials; inputs reach scripts only through environment
  variables.

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
  → latest release `presence-X.Y.Z-GA`. The commit must be on `main`.

Both run [scripts/tag-release.sh](../scripts/tag-release.sh), which refuses
when tracked files have uncommitted changes, when the commit isn't pushed,
or when the tag already exists (tags are unique per minute).
`DRY_RUN=1 bash scripts/release-rc.sh` checks and prints the tag without
creating it. Each GA gets its own new Z, so it's a fresh build of the
commit, not the RC's binaries.

## Versioning

The app version is `X.Y.Z`, resolved by
[scripts/version.sh](../scripts/version.sh):

- **X** and **Y** come from [version.X.txt](../version.X.txt) and
  [version.Y.txt](../version.Y.txt) at the repo root (now `1` and `0`).
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

## Known limitations

- The APK is signed with the runner's throwaway debug key, which differs on
  every run. Google sign-in on Android won't accept it (the Android client
  is matched by the development Mac's debug-key SHA-1), and it can't be
  installed over an earlier build without uninstalling first. A release
  keystore, kept in repository secrets, would fix both.
- The iOS app is unsigned, so it can't be installed on a device as is.
- The Linux bundle is x64 only.
- The build number (Unix seconds) outgrows Android's `versionCode` limit in
  2036.
