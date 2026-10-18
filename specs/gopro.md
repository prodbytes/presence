# GoPro cameras

GoPro cameras become Presence devices, through one Linux
[streamer](streamer.md) of the profile (a Raspberry Pi), which reaches each
camera on its network with the [Open GoPro HTTP
API](https://gopro.github.io/OpenGoPro/http) and fetches its new videos as
if it had recorded them: each video goes through the streamer's chunk
pipeline (sealed, uploaded, searched for people and animals, kept as a
motion event or deleted), as a device of its own. Premium only (the
streamer is). GoPro has no cloud API, so unlike [Blink](blink.md) the
streamer talks to the cameras themselves, with no helper.

A camera is reached in one of three ways (HERO9 or newer):

- **On the home network** (Camera on the Home Network, HERO12 or newer):
  HTTPS, user `gopro` and the camera's password. Its address is an IP
  address; with a password, `https://<address>`.
- **By USB** to the Pi: plain HTTP, no password, `http://172.2x.1yz.51:8080`.
- **On the camera's own Wi-Fi** (the Pi joined to it):
  `http://10.5.5.9:8080`.

Without a password, a bare address means `http://<address>:8080`; a full
`http(s)://host[:port]` URL is taken as it is.

## In the app

Settings' last section, after [Blink cameras](blink.md): **GoPro cameras**
(`NetCameraSettings` with `NetCameraKind.gopro`,
[net_camera_settings.dart](../presence_app/lib/net_camera_settings.dart),
shared with [Reolink](reolink.md)), for a
premium profile with cloud sync, not in DEV:

- **Without a Linux streamer** in the profile (a device whose events say
  `os: Linux`), it says to set one up first.
- **The streamer** that fetches (a dropdown of the profile's Linux
  devices): the one with GoPro cameras already, else the first.
- **Its cameras**, from its status: each camera's name, device ID and
  address, when its videos were last fetched or why they can't be ("Can't
  fetch: …"), and a **Remove** button (`{remove: <device ID>,
  requestedAt}`).
- **Add a camera:** a **name**, its **address** (with where to find it), a
  **password** (home network only), and **Add camera**. The request goes
  to the streamer's folder (`devices/<streamer>/gopro.json`: `{add: {name,
  address, password}, requestedAt}`), **sealed with the streamer's media
  key** (`CloudSync.putDeviceFile`), so only the profile's devices open
  it. "Sent to <streamer>; it looks every 30 s…", then "Reaching the
  camera…", till it answers; the buttons wait meanwhile.
- **The streamer's answer**, `devices/<streamer>/gopro-status.json`
  (sealed with its key; read every 10 s while the section shows,
  `CloudSync.getDeviceFile`): `{state: off | checking | ok | error, error,
  cameras: [{name, deviceId, address, lastFetch, error}], requestedAt}`. An
  error ("GoPro: the camera refused the user or password", "couldn't
  reach …")
  shows in red.
- A send that can't go (the streamer's key not here yet, cloud sync off)
  says so, and the form keeps what was typed.
- GoPro cameras show in the device list with a camera icon
  (`DeviceOs.iconOf('GoPro')`).

## On the streamer

The `netcam` package
([netcam.go](../presence_streamer/internal/netcam/netcam.go), shared with
[Reolink](reolink.md#on-the-streamer): the requests, the status, the
pinned certificate, the fetching) with GoPro's kind, the `gopro` package
([gopro.go](../presence_streamer/internal/gopro/gopro.go)), started by
`main_netcams.go`; on unless `--gopro off`:

- **Every 30 s** it looks for the request in its folder, opens it with
  its key, and handles a newer one than the last it handled
  (`requestedAt`). The request is **deleted from the cloud** once handled,
  whatever happened, so the password doesn't stay there.
- **Add:** it reaches the camera (`GET /gopro/media/list`). Over HTTPS it
  first **pins the camera's certificate** (its SHA-256; the camera signs
  it with its own CA, so it's trusted on first use) and from then on talks
  only to that certificate ("the camera's certificate changed: remove it
  and add it again"). Unreachable, or a password refused: the status says
  so, and nothing is kept. Reached: a new device ID (`ids.NewDevice`), or
  the old one for an address already added, kept with the address,
  password and pin in `gopro-state.json` (mode 600, the state folder). The
  cameras' IDs go with the streamer's credentials requests, as Blink's do
  (see [Streamer](streamer.md#the-stream-key)), so they join the profile's
  devices at once (`Session.Register`).
- **Remove:** the camera is forgotten (its password too) and its pipeline
  stops; its device and events stay.
- **Fetching, every 2 minutes** (`--gopro-every`), each camera in turn:
  its media list's `.MP4` videos newer than the last fetched (a new
  camera's first fetch goes back 24 hours), oldest first. The camera's
  file times are in its own clock (its local time), so the streamer reads
  that clock (`GET /gopro/camera/get_date_time`) and takes its difference
  from UTC, to the quarter hour, off them. Each video is downloaded
  (`/videos/DCIM/<folder>/<file>`) and named like the Pi's chunks with its
  UTC start (`rec-gopro-20261014T120000.mp4`); the streamer moves it into
  **its camera's spool** (`spool/gopro/<device>/`), where a pipeline of its
  own takes it, as for a [Blink camera](blink.md#on-the-streamer): the
  Pi's own settings, the camera's device ID and name (`detail`,
  `cameraLabel`), `cameraId: gopro`, `os: GoPro`, every video kept (no
  motion filter). Where it got to is saved after each video, so a restart
  doesn't fetch it again.
- **Which video:** by default the **low-resolution copy** the camera
  writes beside each video (`GL010002.LRV` for `GX010002.MP4`), when its
  media list says there's one: small enough for a Pi Zero's Wi-Fi and
  detector. `--gopro-video full` fetches the full videos. A video bigger
  than half the spool (`--spool-max-mb`) is skipped and logged.
- **A camera that can't be reached** (asleep, off the network): its error
  shows in the status and is logged once; it's tried again at the next
  fetch. The camera's videos stay on it: nothing is deleted there.

## Tests

- `presence_streamer/internal/gopro` (a fake camera, `httptest`, and the
  `netcamtest` harness: the profile's folder in memory): a camera
  added over HTTPS with its password, its certificate pinned, the request
  deleted (the password nowhere in the cloud), its device registered, the
  videos since the backfill fetched (the `.LRV` when there is one) with
  their UTC start from the camera's clock, each once, also after a
  restart; a wrong password said and nothing kept; a changed certificate
  refused; over USB the full videos, one too big skipped, and remove
  forgets the camera; the same request not handled twice; the addresses
  (`Kind.Base`) and `.LRV` names.
- The app (`net_camera_settings_test.dart`): no streamer; add sends the camera
  to the streamer, then lists it and removes it; an error and a camera's
  own error show; a send that fails says so and keeps the form.

## Known limitations

- **Not tried with a real GoPro yet.**
- The camera must be on and reachable when the streamer fetches; a GoPro
  asleep on the home network isn't woken (that needs Bluetooth).
- Setting up Camera on the Home Network (joining it to the Wi-Fi, getting
  its password) is done with GoPro's tools, not Presence.
- A video still being recorded isn't in the media list till it's done; a
  long recording's chapters come as separate videos.
- Up to 16 cameras per streamer, Blink's, GoPro's and Reolink's together
  (the auth API's limit).
