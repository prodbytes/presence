# Blink cameras

A Blink account's cameras become Presence devices, through one Linux
[streamer](streamer.md) of the profile (a Raspberry Pi), which fetches
their clips with [blinkpy](https://pypi.org/project/blinkpy/) and streams
them as if it had recorded them: each clip goes through the streamer's
chunk pipeline (sealed, uploaded, searched for people and animals), as a
device of its own, and **every clip is kept** as a motion event, tagged
with whoever's in it (`KeepAll`: Blink records only on motion). Premium only (the
streamer is).

## In the app

Settings' last section, **Blink cameras** (`BlinkSettings`,
[blink_settings.dart](../presence_app/lib/blink_settings.dart)), for a
premium profile with cloud sync, not in DEV:

- **Without a Linux streamer** in the profile (a device whose events say
  `os: Linux`), it says to set one up first (Profile › Stream from a
  Raspberry Pi).
- **The streamer** that fetches (`StreamerPicker`,
  [streamer_picker.dart](../presence_app/lib/streamer_picker.dart)): a
  dropdown whose first entry, the default, is **Leader (<device>)**: the
  profile's [leading streamer](streamer-leader.md) (`DeviceSlots.leader`),
  whichever it is at each refresh, so a new leader is followed (its status
  read, the requests sent to it). With no leader known yet, or one that
  isn't among the profile's Linux devices, it's the first of them,
  "Leader (none yet; <device> for now)". Then the profile's Linux devices,
  the leader first: picking one keeps it **for Blink only**
  (`IntegrationsConfig`, [Configuration](configuration.md)), and that
  streamer is used even when another leads; picking Leader again clears
  it. A picked streamer no longer among the profile's Linux devices gives
  way to the leader, its pick kept (the list fills as events load, so a
  streamer missing for a moment isn't forgotten). **Only the leader
  fetches**: the request goes to the streamer shown alone, and it fetches
  only while it leads, so a streamer picked by hand fetches only while it
  leads (the dropdown's help says so).
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
  hours), not deleted. Blink's own `since` is when a clip last changed,
  so it returns older clips too: the helper skips any made before where
  fetching got to, or a clip would be fetched again at every fetch. Each
  goes to its camera's folder, named like the Pi's
  chunks with their UTC start (`rec-blink-20261014T120000.mp4`), and the
  streamer moves each into **its camera's spool**
  (`spool/blink/<device>/`), where a pipeline of its own takes it: the
  Pi's own settings (detection here or in the cloud, the object scores,
  the spool's size), but the camera's device ID, its name as the camera
  (`detail`, `cameraLabel`, and the event's **`cameraName`**, which the
  app shows before the device: "Garden | device"), `cameraId: blink`,
  `os: Blink`, and **every clip kept**: no motion filter, and kept with
  no one in it too (the pipeline's `KeepAll`, in the cloud detector's
  mode too; Blink records on motion already). Its events say when they
  were stored (`storedAt`). Then the app's [recognition](recognition.md)
  searches them as it does the streamer's own clips: one device that can
  recognize, for subjects and objects. Its
  settings (`devices/<camera>/settings.json`, the streamer's media key)
  go up first, as for the Pi's own device, so the other devices open its
  clips. Its sealed clips carry its own device ID as their key's ID.
- **Deleted from the device once verified:** a clip, its sealed copy and
  thumbnail leave the Pi only as the Pi's own chunks do, once each upload
  is verified in the bucket by size and MD5
  ([Streamer](streamer.md#each-chunk), step 8); one that fails
  verification stays and is tried again. A clip downloaded but never
  handed to its pipeline (the streamer stopped before it read the
  helper's answer, and the helper skips a clip it finds downloaded; a
  hand-over that failed) is handed over after the next fetch, so none
  stays in `blink-incoming/` unsent; a download cut off (`.part`) is
  deleted there, and fetched again while Blink lists it (where fetching
  got to moves on only after a whole fetch).
- **A token Blink refuses** (the helper exits 2): fetching stops, and the
  status says "log in again", till a new login.
- **Disconnect:** the token goes; the cameras' devices and events stay.

## Tests

- `presence_streamer/internal/blink`: a login with a PIN relayed from the
  request (the request deleted after, the password in no file), the
  cameras' devices (a new camera from a fetch gets one too), clips handed
  to their camera's device, the same request not handled twice; a wrong
  password said and nothing kept; a refused token stops fetching;
  disconnect forgets the token; a clip left downloaded before a stop
  handed over once at the next fetch, a cut-off download deleted, nothing
  left in `blink-incoming/`. `main_cameras_test.go`: a clip through its
  camera's pipeline, its first upload failing verification, stored once
  verified, then deleted from the device. The tests' clock starts at 2026-10-14
  13:00 UTC, an hour after the fake clips, and runs at real speed, so the
  24-hour backfill always covers them. `rclone`: `Get`, and a missing object is
  `os.ErrNotExist`. `records`: a Blink camera's events say `os: Blink`.
- The auth API (`ProfileTest`): a streamer's cameras join the profile's
  devices under its key; bad or too many camera IDs are refused; its
  cameras don't make another device's key good.
- The app (`blink_settings_test.dart`): no streamer; connect sends the
  login to the streamer, then the PIN without the password, then shows its
  cameras and disconnects; an error shows with the form; a send that
  fails says so; the streamer is the leader by default, a new leader
  followed at the next refresh, the first while none is known; one picked
  sticks when another leads, is kept in the config, and Leader clears it;
  a picked one that's gone gives way to the leader. `config_test.dart`:
  `IntegrationsConfig` round-trips, ignoring unknown integrations and bad
  IDs.
- By hand: the helper with blinkpy 0.25.9 reached Blink, which refused a
  made-up login (`exit 2`, no token kept).

## Known limitations

- **Only the leading streamer fetches.** Blink's login stays on the
  streamer that logged in: when another takes the lead, the section (on
  Leader) shows the new leader, not connected, and you connect again. A
  streamer picked by hand fetches only while it leads.

- **Not tried with a real Blink account yet.**
- Clips stored on a Sync Module's USB drive (no Blink subscription) aren't
  fetched: blinkpy's cloud clip list only.
- A Blink camera's device deleted in the app is added again at the next
  credentials renewal while the streamer still fetches for it; disconnect
  Blink first.
