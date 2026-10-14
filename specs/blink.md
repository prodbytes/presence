# Blink cameras

A Blink account's cameras become Presence devices, through one Linux
[streamer](streamer.md) of the profile (a Raspberry Pi), which fetches
their clips with [blinkpy](https://pypi.org/project/blinkpy/) and streams
them as if it had recorded them: each clip goes through the streamer's
chunk pipeline (sealed, uploaded, searched for people and animals, kept
as a motion event or deleted), as a device of its own. Premium only (the
streamer is).

## In the app

Settings' last section, **Blink cameras** (`BlinkSettings`,
[blink_settings.dart](../presence_app/lib/blink_settings.dart)), for a
premium profile with cloud sync, not in DEV:

- **Without a Linux streamer** in the profile (a device whose events say
  `os: Linux`), it says to set one up first (Profile › Stream from a
  Raspberry Pi).
- **The streamer** that fetches (a dropdown of the profile's Linux
  devices): the one with Blink already, else the first. **Only that one
  fetches**: the request goes to it alone.
- **Not connected:** the Blink account's **email** and **password**, and
  **Connect**. The request goes to the streamer's folder
  (`devices/<streamer>/blink.json`: `{email, password, requestedAt}`),
  **sealed with the streamer's media key** (`CloudSync.putDeviceFile`), so
  only the profile's devices open it. "Sent to <streamer>; it looks every
  30 s…" until it answers.
- **The streamer's answer**, `devices/<streamer>/blink-status.json`
  (sealed with its key; read every 10 s while the section shows,
  `CloudSync.getDeviceFile`): "Installing Blink support on the streamer
  (once)…", "Logging in to Blink…", then:
  - **"Blink sent a PIN to <account>'s email or phone: enter it here."**,
    a **PIN** field and **Send PIN**: the same request again
    (`{email, pin, requestedAt}`), without the password;
  - **"Connected to Blink as <account>. Its cameras:"**, each camera's
    name and its device ID, when clips were last fetched, and
    **Disconnect** (`{disconnect: true, requestedAt}`);
  - an error ("Blink: Blink refused the login (email, password or PIN)"),
    with the form again.
- A send that can't go (the streamer's key not here yet, cloud sync off)
  says so.
- Blink cameras show in the device list with a camera icon
  (`DeviceOs.iconOf('Blink')`).

## On the streamer

`blink` package ([blink.go](../presence_streamer/internal/blink/blink.go))
and `main_blink.go`; on unless `--blink off`:

- **Every 30 s** it looks for the request in its folder (`rclone copyto`,
  `Folder.Get`), opens it with its key, and handles a newer one than the
  last it handled (`requestedAt`).
- **Login:** the helper, `presence-blink.py`
  ([detector/presence-blink.py](../presence_streamer/detector/presence-blink.py)),
  runs blinkpy **0.25.9** in its own virtualenv in the state folder
  (`blink-venv`, made the first time: `python3 -m venv`, then `pip install
  blinkpy==0.25.9`; Debian doesn't package blinkpy, so the package
  suggests `python3-venv`). It gets `{email, password}` on its standard
  input, never a file or the command line. When Blink sends a 2FA PIN, the
  helper says `pin-required` and waits (blinkpy's OAuth state is in
  memory): the streamer says so in the status, waits up to 10 minutes for
  the request to come again with a PIN, and passes it on.
- **Logged in:** blinkpy's token goes to `blink-token.json` (mode 600),
  **never the password**; the request is **deleted from the cloud**,
  whatever happened, so the password doesn't stay there. A wrong password
  or PIN: the status says so, and nothing is kept.
- **Each camera a device:** a new device ID (`ids.NewDevice`, the app's
  words) the first time it's seen, kept in `blink-state.json`. The
  cameras' IDs go with the streamer's credentials requests
  (`POST /api/auth/stream/credentials`, after its own ID: see
  [Streamer](streamer.md#the-stream-key)), so they join the profile's
  devices, at once when a camera is new (`Session.Register`). With a Google
  sign-in instead of a stream key they don't (they still show in the
  device list from their events).
- **Fetching, every 2 minutes** (`--blink-every`): the helper downloads
  the clips Blink made since the last fetch (the first time, the last 24
  hours), not deleted, each to its camera's folder, named like the Pi's
  chunks with their UTC start (`rec-blink-20261014T120000.mp4`), and the
  streamer moves each into **its camera's spool**
  (`spool/blink/<device>/`), where a pipeline of its own takes it: the
  Pi's own settings (detection here or in the cloud, the object scores,
  the spool's size), but the camera's device ID, its name as the camera
  (`detail`, `cameraLabel`), `cameraId: blink`, `os: Blink`, and **every
  clip kept** (no motion filter: Blink records on motion already). Its
  settings (`devices/<camera>/settings.json`, the streamer's media key)
  go up first, as for the Pi's own device, so the other devices open its
  clips. Its sealed clips carry its own device ID as their key's ID.
- **A token Blink refuses** (the helper exits 2): fetching stops, and the
  status says "log in again", till a new login.
- **Disconnect:** the token goes; the cameras' devices and events stay.

## Tests

- `presence_streamer/internal/blink`: a login with a PIN relayed from the
  request (the request deleted after, the password in no file), the
  cameras' devices (a new camera from a fetch gets one too), clips handed
  to their camera's device, the same request not handled twice; a wrong
  password said and nothing kept; a refused token stops fetching;
  disconnect forgets the token. `rclone`: `Get`, and a missing object is
  `os.ErrNotExist`. `records`: a Blink camera's events say `os: Blink`.
- The auth API (`ProfileTest`): a streamer's cameras join the profile's
  devices under its key; bad or too many camera IDs are refused; its
  cameras don't make another device's key good.
- The app (`blink_settings_test.dart`): no streamer; connect sends the
  login to the streamer, then the PIN without the password, then shows its
  cameras and disconnects; an error shows with the form; a send that
  fails says so.
- By hand: the helper with blinkpy 0.25.9 reached Blink, which refused a
  made-up login (`exit 2`, no token kept).

## Known limitations

- **Not tried with a real Blink account yet.**
- Clips stored on a Sync Module's USB drive (no Blink subscription) aren't
  fetched: blinkpy's cloud clip list only.
- A Blink camera's device deleted in the app is added again at the next
  credentials renewal while the streamer still fetches for it; disconnect
  Blink first.
