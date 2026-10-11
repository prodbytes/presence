# Install script

[scripts/install.sh](../scripts/install.sh) downloads, extracts and runs the
latest release on the machine it runs on:

```sh
curl -fsSL https://sh.presence.nu01.com | sh
```

https://sh.presence.nu01.com serves the script at every path (see
[Install URL](install-url.md)); its raw GitHub URL on `main` works too.

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
- `PRESENCE_KIOSK=1` installs the [Raspberry Pi camera](raspberry-pi.md)
  instead (`curl -fsSL https://sh.presence.nu01.com | PRESENCE_KIOSK=1 sh`):
  on Linux arm64 with `apt-get`, it downloads
  `presence-<tag>-raspberrypi-arm64.deb` and installs it with
  `sudo apt-get install -y` (no sudo as root). Since that runs as root,
  the checksum is required: if the release API can't give it, it stops
  rather than install unverified. It doesn't fall back to the web app;
  it exits non-zero on failure. Elsewhere it says the kiosk is for 64-bit
  Raspberry Pi OS.
- On a Raspberry Pi (`/proc/device-tree/model`) on arm64, the normal run
  prints a tip with the `PRESENCE_KIOSK=1` command.

Verified in Ubuntu 24.04 containers: on amd64 with GTK, EGL, GLES and Xvfb
the GA x64 bundle downloads, extracts, starts and stays up (a second run
reuses it); without EGL/GLES, or without a display, it falls back to the
web app; on arm64, against a GA without an arm64 bundle, it falls back to
the web app. The checksum lookup was checked against the GA's real digest.

## Raspberry Pi

Raspberry Pi OS **64-bit** (Bookworm or newer), from the desktop:

```sh
sudo apt install -y curl libgtk-3-0 libegl1 libgles2
curl -fsSL https://sh.presence.nu01.com | sh
```

Verified on Debian 12 arm64 (Raspberry Pi OS Bookworm's base) with those
packages and Xvfb: the live URL runs the `0.5.202610021114-GA` arm64
bundle. The 32-bit OS (`armv7l`) has no native build and gets the web app.
The README's "Raspberry Pi" section has the same steps, and the camera
`.deb`.

## Streamer

[scripts/install-streamer.sh](../scripts/install-streamer.sh), served at
https://sh.presence.nu01.com/streamer ([Install URL](install-url.md)),
installs the [streamer](streamer.md) on a Raspberry Pi and sets it up for a
profile, so it streams from every boot:

```sh
curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- automatic_paranoid_axolotl
curl -fsSL https://sh.presence.nu01.com/streamer | PRESENCE_PROFILE=automatic_paranoid_axolotl sh
```

- **The profile** is the first argument, else `PRESENCE_PROFILE`. Without
  one, or with one that isn't a profile ID (`a_b_c`, at most 64), it says
  how to run it and exits 2.
- **The app shows the command**, with the profile filled in, to copy and
  paste on the Pi: the account sheet's **Stream from a Raspberry Pi** box
  (`StreamerCommand`, [streamer_command.dart](../presence_app/lib/auth/streamer_command.dart)),
  under the plan, for a premium profile (or an admin) with access, not in
  DEV. It has the command (selectable, monospace) and **Copy command**,
  which copies it and says so. Only an ID of lowercase letters and
  underscores makes a command (no shell quoting needed), else the box
  doesn't show.
- **POSIX `sh`**, one `main` call at the end, as the main script. Needs
  Linux with `apt-get` and `dpkg`. The architecture is `dpkg
  --print-architecture`: `armhf` (32-bit) or `arm64` (64-bit), anything
  else refused.
- **The release:** the latest GA (from the `releases/latest` redirect), or
  `PRESENCE_TAG`. It downloads `presence-streamer-<tag>-raspberrypi-<arch>.deb`
  and **requires** its sha256 from the release API, since it installs as
  root. A mismatch, or no checksum, stops it.
- **Installs** with `sudo apt-get update` and `sudo apt-get install -y`
  (no sudo as root), which brings ffmpeg, rclone and OpenCV. The package
  enables `presence-streamer.service` for every boot.
- **Sets up** with `sudo presence-streamer setup --profile <ID>`, its stdin
  the terminal (`/dev/tty`, since the script's own stdin is curl's pipe).
  That shows the Google sign-in code, checks the profile is Premium, and
  starts the service. Without a terminal it says the command to run.
- Verified in Docker (Debian 13 arm64, Debian 12 armhf emulated), with a
  fake `curl` serving the release's `.deb` and the API's checksum: without
  a profile, or with `x; rm -rf /`, it exits 2; a wrong checksum stops it
  before apt; it installs the package and its dependencies, the boot link
  is made, and `setup` gets the profile from the argument and from
  `PRESENCE_PROFILE` (stopping there, at the sign-in, for want of the
  Google client in a local build).

## Known limitations

- When the release API is unreachable or rate-limited, the download isn't
  checksum-verified (it still comes over HTTPS from GitHub); the script
  says so.
- The web fallback is the hosted GA app, not the release's `web.zip`, so it
  needs a network connection, and `PRESENCE_TAG` doesn't change it.
- The native app's exit status can't tell a crash from the app being
  killed, so either opens the web app.
- Old releases stay in `~/.local/share/presence/`; nothing prunes them.
