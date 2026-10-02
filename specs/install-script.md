# Install script

[scripts/install.sh](../scripts/install.sh) downloads, extracts and runs the
latest release on the machine it runs on:

```sh
curl -fsSL https://raw.githubusercontent.com/prodbytes/presence/main/scripts/install.sh | sh
```

- **POSIX `sh`** (works with dash), needing only `curl`, `tar` and
  `sha256sum` (or `shasum`). The whole script is one `main` call at the end,
  so a truncated download runs nothing.
- **Release:** the latest GA, read from the `releases/latest` redirect
  rather than the API, which rate-limits anonymous calls. `PRESENCE_TAG`
  picks another tag.
- **Native app** (Linux `x86_64` → `x64`, `aarch64` → `arm64`): downloads
  `presence-<tag>-linux-<arch>.tar.gz` from the release, checks its sha256
  against the digest the release API lists for the asset, and extracts it to
  `${XDG_DATA_HOME:-~/.local/share}/presence/<tag>/bundle/`. A release
  already there is reused, not downloaded again. Then it runs
  `bundle/presence_app`.
- **Web fallback:** it opens https://presence.nu01.com (the GA web app) with
  `xdg-open` (or `open` on macOS), or prints the URL when there's no
  browser, when:
  - the OS or CPU has no native build (e.g. macOS, Windows, 32-bit ARM);
  - the latest tag can't be found, or the release has no bundle for the
    architecture (GA releases before arm64 builds were added);
  - the checksum doesn't match;
  - there's no display (`DISPLAY` / `WAYLAND_DISPLAY`);
  - libraries are missing: those `ldd` reports, plus `libEGL.so.1` and
    `libGLESv2.so.2`, which Flutter loads at run time (it names the Debian
    packages `libgtk-3-0 libegl1 libgles2`);
  - the native app exits with a non-zero status.
- `PRESENCE_WEB=1` skips the native app and opens the web app.

Verified in Ubuntu 24.04 containers: on amd64 with GTK, EGL, GLES and Xvfb
the GA x64 bundle downloads, extracts, starts and stays up (a second run
reuses it); without EGL/GLES, or without a display, it falls back to the
web app; on arm64, against a GA without an arm64 bundle, it falls back to
the web app. The checksum lookup was checked against the GA's real digest.

## Known limitations

- When the release API is unreachable or rate-limited, the download isn't
  checksum-verified (it still comes over HTTPS from GitHub); the script
  says so.
- The web fallback is the hosted GA app, not the release's `web.zip`, so it
  needs a network connection, and `PRESENCE_TAG` doesn't change it.
- The native app's exit status can't tell a crash from the app being
  killed, so either opens the web app.
- Old releases stay in `~/.local/share/presence/`; nothing prunes them.
