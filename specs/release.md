# Release builds

[.github/workflows/release.yml](../.github/workflows/release.yml) builds the
app binaries with `make` and publishes them as a GitHub release.

- **Triggers:**
  - A pushed tag matching `*QA` or `*RC*` (e.g. `1.2.0-QA`, `1.2.0-RC1`)
    is released as a **prerelease** under that tag.
  - **Manual dispatch** (Actions → Release → Run workflow) takes an
    optional `tag` and a `prerelease` switch (on by default). An empty tag
    uses the selected ref if it's a tag, or `manual-<run number>`. A tag
    that doesn't exist yet is created on the dispatched commit.
  - **Pull requests** that change the workflow, the `Makefile`,
    `scripts/make.sh` or `scripts/dart-defines.sh` run the builds only,
    without a release.
  - Tag names must be letters, digits, `.`, `_` and `-`.
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

## Known limitations

- The APK is signed with the runner's throwaway debug key, which differs on
  every run. Google sign-in on Android won't accept it (the Android client
  is matched by the development Mac's debug-key SHA-1), and it can't be
  installed over an earlier build without uninstalling first. A release
  keystore, kept in repository secrets, would fix both.
- The iOS app is unsigned, so it can't be installed on a device as is.
- The Linux bundle is x64 only.
