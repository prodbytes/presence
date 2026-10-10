# Raspberry Pi camera (.deb)

`presence-<tag>-raspberrypi-arm64.deb` makes a Raspberry Pi (Raspberry Pi
OS 64-bit, Bookworm or newer; Debian arm64 works the same) a Presence
camera: Presence runs full screen from boot, comes back after a crash, and
needs no keyboard. The README's "Raspberry Pi" section is the how-to.

## What the camera runs

**The web app in Chromium, by default**, because the native Linux app
can't be a camera yet:

- **No camera layer on Linux.** The native camera code
  ([native_cameras.dart](../presence_app/lib/cameras/native_cameras.dart))
  talks to the `presence/cameras` and `presence/motion` channels, which only
  Android (Kotlin) and iOS (Swift) implement. The Linux runner registers
  only `gtk` and `url_launcher_linux`, so the camera screen fails with a
  `MissingPluginException` ("Could not open the camera"). Making the native
  app a camera needs a Linux implementation of that channel API in the
  runner: GStreamer (`v4l2src` for USB, `libcamerasrc` for the camera
  module) feeding a Flutter pixel-buffer texture for the preview, 64×48
  luma frames for motion, and an H.264 + AAC ring buffer muxed to MP4 for
  clips.
- **No Google sign-in on Linux.** `google_sign_in` has no Linux
  implementation, so the native app says "Google sign-in is unavailable"
  and can't sync. It would need its own OAuth flow (e.g. a loopback
  redirect in the system browser).

The web app has neither gap: `getUserMedia` opens USB (UVC) webcams and the
microphone through Chromium, and Google sign-in works as in any browser.
`PRESENCE_KIOSK_APP=native` shows the native app instead (installed
anyway, and the `presence` command), for when it gets a camera layer.

## Package

[scripts/deb.sh](../scripts/deb.sh) builds it from a Linux bundle and
[packaging/raspberrypi/](../packaging/raspberrypi); `make deb` (Linux only)
builds the bundle and runs it, writing
`presence_app/build/deb/presence_<version>_<arch>.deb`. The release
workflow's `linux-arm64` job runs `make deb` and uploads it as
`presence-<tag>-raspberrypi-arm64.deb` (see [Release builds](release.md)).

| Path | What |
|---|---|
| `/opt/presence/bundle/` | the native Flutter bundle; `/usr/bin/presence` links to it |
| `/opt/presence/lib/kiosk-session` | the service's command: cage on tty1 |
| `/opt/presence/lib/kiosk-app` | what cage shows: Chromium, or the native app |
| `/usr/sbin/presence-kiosk` | `enable`, `disable`, `restart`, `status` |
| `/lib/systemd/system/presence-kiosk.service` | the kiosk service |
| `/etc/default/presence` | settings (conffile) |
| `/etc/pam.d/presence-kiosk` | the kiosk's logind session (conffile) |
| `/etc/chromium/policies/managed/presence.json` | camera and mic allowed for Presence (conffile) |
| `/usr/share/polkit-1/rules.d/50-presence-kiosk.rules` | denies the `presence` user power, network and storage actions |
| `/var/lib/presence/` | the `presence` user's home: the Chromium profile (sign-in, events, clips) |

- **Depends:** `cage`, `xwayland` (Debian's cage won't start without it),
  `chromium | chromium-browser`, and the bundle's libraries (`libgtk-3-0`,
  `libglib2.0-0 (>= 2.72)`, `libc6 (>= 2.35)`, `libegl1`, `libgles2`,
  `libepoxy0`, `libfontconfig1`, `libstdc++6`, `libgcc-s1`), from `ldd` of
  the arm64 bundle on Debian 12. **Recommends:** `libcamera-v4l2`
  (`libcamerify`).

## Boot and kiosk

- **`presence-kiosk.service`** (`WantedBy=multi-user.target`, so it starts
  on Lite, which boots to `multi-user.target`, and on the desktop image)
  runs `kiosk-session` as the **`presence` system user** (home
  `/var/lib/presence`, mode 700; shell `nologin`; groups `video`, `audio`,
  `render`) on **tty1**, replacing its getty (`Conflicts=getty@tty1`).
  `PAMName=presence-kiosk` opens a logind session on seat0, which gives
  the compositor the screen and input devices without root.
- **Restart:** `Restart=always`, `RestartSec=5`, and
  `StartLimitIntervalSec=0` so it never stops retrying. When Chromium (or
  the native app) exits, cage exits, and systemd starts both again.
- **cage** (`-d -s`: no decorations, VT switching allowed) shows one app
  full screen. `WLR_LIBINPUT_NO_DEVICES=1` lets it start with no keyboard
  or mouse. With no screen connected (no `connected` DRM connector) it
  runs on a headless output, so the camera still records.
- **No blanking:** cage has no idle timeout, so the screen stays on.
- **Hardening** (in the unit), all compatible with Chromium's sandbox:
  `NoNewPrivileges`, `ProtectSystem=strict` with `ReadWritePaths=` the
  home (`/var/lib/presence`) and `/run/user` (the logind session's
  runtime directory, where cage puts its Wayland socket), `PrivateTmp`,
  `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectKernelLogs`,
  `ProtectControlGroups`, `RestrictSUIDSGID`, `LockPersonality`, and
  `InaccessiblePaths=/home /root`.
  - **Not `ProtectHome=yes`** (the unit had it before): it also hides
    `/run/user`, so the runtime directory wasn't writable and cage
    couldn't create its socket under systemd.
  - Left out on purpose: `RestrictNamespaces=` (Chromium's sandbox puts
    renderers in their own user namespace), `MemoryDenyWriteExecute=`
    (V8's JIT, WebAssembly), `PrivateDevices=` (camera, GPU, input),
    `PrivateUsers=` and `SystemCallFilter=` (Chromium installs its own
    seccomp filters).
  - With `NoNewPrivileges`, Chromium's setuid sandbox can't be used, so it
    needs unprivileged user namespaces, which Raspberry Pi OS and Debian
    12 enable; it prefers them anyway.
- **polkit:** a rule denies the `presence` user (the active seat0 session,
  which logind lets power off or reboot without asking) every
  `org.freedesktop.login1` power-off, reboot, halt, suspend, hibernate and
  reboot-setting action, NetworkManager, wpa_supplicant, systemd-networkd
  and -resolved, ModemManager and UDisks2 actions. Other actions (e.g.
  idle inhibitors) are left to their defaults.
- **Chromium** (`chromium` or `chromium-browser`) runs `--kiosk` on
  Wayland with its profile in `/var/lib/presence/chromium`, which keeps the
  sign-in and the app's IndexedDB events and clips across reboots. Before
  each start, the profile's last exit is marked clean, so a power cut
  doesn't bring a "restore pages" bubble. It waits up to a minute for the
  URL's host to resolve at boot. `--deny-permission-prompts` denies any
  prompt (e.g. location: set it on the map in Settings), while the managed
  policy allows the camera and microphone for `https://presence.nu01.com`
  and `https://rc.presence.nu01.com` without asking. The policy is
  machine-wide, so a desktop user's Chromium gets the same allowance for
  those two origins.
- **Camera module:** `PRESENCE_LIBCAMERIFY=auto` runs Chromium under
  `libcamerify` when it's installed and no USB (`uvcvideo`) webcam is
  plugged in.

### Settings (`/etc/default/presence`)

| Setting | Default | |
|---|---|---|
| `PRESENCE_KIOSK_APP` | `web` | `web` or `native` |
| `PRESENCE_URL` | `https://presence.nu01.com/app/` | https only; another origin needs adding to the Chromium policy |
| `PRESENCE_LIBCAMERIFY` | `auto` | `auto`, `1`, `0` |
| `PRESENCE_CHROMIUM_FLAGS` | empty | extra flags, split on spaces |

## Install, upgrade, remove

- **postinst:** creates the `presence` user and its groups. On a **fresh
  install** (or an install after a remove) it enables the service, unless
  a display manager is enabled (the
  `/etc/systemd/system/display-manager.service` link): then it says so and
  leaves the desktop alone. It **starts** the kiosk now only when systemd
  is running and the install doesn't run from **tty1**, the kiosk's own
  console (this process or an ancestor has tty1 as its controlling
  terminal, read from `/proc/<pid>/stat`; sudo's `use_pty` doesn't hide
  it): starting there would take tty1 from under the install. Otherwise it
  says the kiosk starts at the next boot and asks for a reboot. On
  **upgrade** it only restarts the service if it's enabled and running
  (and not from tty1); a kiosk turned off stays off.
- **`presence-kiosk enable`** enables the service; on a desktop image it
  also disables the display manager, remembering which in
  `/var/lib/presence-kiosk/display-manager` (root-owned, checked to be a
  plain unit name), and asks for a reboot if the desktop is running, or
  if it runs from tty1 (as postinst).
  **`disable`** turns the kiosk off and re-enables that display manager.
- **prerm** (remove only) runs `presence-kiosk disable`. **postrm** on
  purge deletes `/var/lib/presence` and `/var/lib/presence-kiosk`; dpkg
  deletes the conffiles. The `presence` user stays, as Debian does with
  system users.
- [The install script](install-script.md) installs it with
  `PRESENCE_KIOSK=1`.

## Signing in

The first boot shows the recording consent screen, then the camera,
signed out: with a mouse and keyboard, tap **I agree** and sign in with
Google, with the account the other devices use (joining through an
[Add a device](add-device.md) link is the same sign-in). The Google
session is kept in the Chromium profile, so after a reboot the web app's
silent FedCM sign-in restores it, as in any browser ([Sign-in](sign-in.md)).

## Verified

In a Debian 12 arm64 container booted with systemd (2026-10-07), with
Chromium 154 from Debian and the package built by `scripts/deb.sh` from a
stub bundle:

- A transient unit with the service's user, a PAM session and exactly its
  hardening: `XDG_RUNTIME_DIR` (`/run/user/<uid>`) and the home are
  writable, `/etc` read-only, `/dev/shm` writable, unprivileged user
  namespaces work, and headless Chromium (no `--no-sandbox`) renders a
  page with its renderers in their own user namespace and under seccomp.
  The same with `ProtectHome=yes` left `XDG_RUNTIME_DIR` inaccessible
  (permission denied), hence the change.
- `apt install` of the package: `systemd-analyze verify` passes, the
  polkit rule loads (`Finished loading, compiling and executing 3
  rules`), and `pkcheck` as `presence` is refused `login1.power-off`,
  `login1.reboot-multiple-sessions`, `udisks2.filesystem-mount` and
  `NetworkManager.network-control` (registered as allowed for anyone for
  the test) but still allowed `login1.inhibit-block-idle`; another user
  is unaffected.
- The tty1 check finds a controlling terminal through a parent process
  with stdin redirected (a pseudo-terminal in the test; tty1 is the same
  check with tty1's number, 1025).

Not yet on a Raspberry Pi with a screen (cage and the real tty1).

Earlier:

In Debian 12 arm64 containers (Raspberry Pi OS Bookworm's base), with the
`0.6.202610061530-RC` arm64 bundle:

- `scripts/deb.sh` builds the package; `apt install ./…deb` resolves every
  dependency from Debian; `systemd-analyze verify` passes; shellcheck is
  clean; the user, groups, modes, conffiles and the service link are as
  above; every library the bundle links is found.
- Upgrades keep data and a disabled kiosk off; remove keeps settings and
  data; install after remove re-enables it; purge deletes both; with a
  (fake) display manager enabled, install leaves it alone, `enable` swaps
  it out, and `disable` or remove brings it back.
- Running `kiosk-session` as `presence` (headless cage, pixman renderer):
  Chromium opens the GA web app, the camera permission is `granted` with
  no prompt, `getUserMedia` gets video and audio (Chromium's fake device),
  and after **I agree** the camera screen shows the live feed. The native
  mode starts the bundle under cage.

Not verified on a real Raspberry Pi: tty1/logind handoff, the camera
module through `libcamerify`, and the headless fallback on hardware.

## Known limitations

- The camera is the web app: it needs the network to load
  presence.nu01.com at boot, and records what the web app records (WebM).
- The native Linux app has no camera layer or Google sign-in (above).
- The first setup (consent, sign-in) needs a mouse and keyboard or touch
  screen.
- If Google's session in the profile ends (password change, sign-out
  elsewhere), the Pi stays signed out until someone signs in on it again.
- A screen plugged in after boot isn't used until the service restarts.
- Chromium needs a Pi 4 or 5 with 2 GB or more; a Pi 3 (1 GB) is tight.
