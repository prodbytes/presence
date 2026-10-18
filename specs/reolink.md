# Reolink cameras

Reolink cameras (or a Reolink NVR's cameras) become Presence devices,
through one Linux [streamer](streamer.md) of the profile (a Raspberry Pi),
which logs in to each camera with its HTTP API (`/cgi-bin/api.cgi`) and
fetches the recordings it made, on motion, on its SD card or the NVR's
disk, as if it had recorded them: each recording goes through the
streamer's chunk pipeline (sealed, uploaded, searched for people and
animals, kept as a motion event or deleted), as a device of its own.
Premium only (the streamer is). It works like [GoPro cameras](gopro.md)
(the same `netcam` package and Settings widget), with a login and an NVR
channel.

The camera must record (an SD card, or an NVR's disk) and have HTTPS on
(its network settings, Advanced › Server settings: on by default on most).
Its password goes only over HTTPS: a plain `http://` address is refused.
Battery cameras that sleep (Argus, without a Home Hub) don't answer the
API.

## In the app

Settings' last section, after [GoPro cameras](gopro.md): **Reolink
cameras** (`NetCameraSettings` with `NetCameraKind.reolink`,
[net_camera_settings.dart](../presence_app/lib/net_camera_settings.dart)),
for a premium profile with cloud sync, not in DEV. As GoPro's (the
streamer dropdown, the cameras with their last fetch or error, Remove,
"Sent to …", a send that can't go), but adding a camera asks for:

- a **name**, its **address** (its IP address, as the Reolink app shows it
  under Network information, or `https://host[:port]`);
- the **user** (`admin` already filled in) and the **password**, which is
  needed (nothing is sent without it);
- the **channel** (`0` already): an NVR's camera, from 0; 0 for a camera
  on its own.

The request goes to `devices/<streamer>/reolink.json` (`{add: {name,
address, username, password, channel}, requestedAt}`; the channel only
when it's not 0), sealed with the streamer's media key; the answer is
`devices/<streamer>/reolink-status.json`. A camera's line shows its
address and, on an NVR, "channel N". Reolink cameras show in the device
list with a camera icon (`DeviceOs.iconOf('Reolink')`).

## On the streamer

The `netcam` package
([netcam.go](../presence_streamer/internal/netcam/netcam.go)) with
Reolink's kind, the `reolink` package
([reolink.go](../presence_streamer/internal/reolink/reolink.go)), started
by `main_netcams.go`; on unless `--reolink off`. The requests, the
status, deleting the request from the cloud, the pinned certificate, the
device IDs and their registration, the pipelines and where fetching got
to are as for [GoPro](gopro.md#on-the-streamer), in `reolink-state.json`
(mode 600) and `spool/reolink/<device>/`, its events `cameraId: reolink`,
`os: Reolink`. What's Reolink's:

- **Login** (`cmd=Login`, the user and password in the body, over
  HTTPS): the token the other commands carry; a refused login says "the
  camera refused the user or password", and nothing is kept. Each fetch
  logs in, and **logs out** after (`cmd=Logout`): cameras allow few
  sessions. The same address and channel again keep their device.
- **Its clock** (`cmd=GetTime`): the recordings' times are the camera's
  local time; its difference from UTC, to the quarter hour, is taken off
  them, as for GoPro.
- **Fetching, every 2 minutes** (`--reolink-every`): a search
  (`cmd=Search`, the camera's channel) for each day since the newest
  recording fetched (a new camera's first fetch goes back 24 hours; at
  most 7 days back: each day is a search, at every fetch). By default the
  **sub stream's** recordings (low resolution, small for a Pi Zero),
  and on a day the camera has none of those, the main stream's;
  `--reolink-video full` fetches the main stream's. Each recording is
  downloaded (`cmd=Download&source=<its path>`; an answer in JSON is an
  error) and named by its UTC start (`rec-reolink-20261014T120000.mp4`).
  One bigger than half the spool is skipped. The recordings stay on the
  camera.

## Tests

- `presence_streamer/internal/reolink` (a fake camera: its login, tokens,
  clock, a day's search, downloads and logouts, over `httptest` TLS, with
  the `netcamtest` harness): added, logged in, the certificate pinned, the
  request deleted (the password nowhere in the cloud), the sub stream's
  recordings since the backfill fetched (the main stream's on a day with
  no sub stream), another channel's left out, each once, also after a
  restart, every session logged out; an NVR channel with full videos; a
  wrong password said and nothing kept; the addresses (`Kind.Base`: HTTPS
  only, a password needed).
- The app (`net_camera_settings_test.dart`): without a password nothing is
  sent; the user, password and channel go to `reolink.json`; the camera's
  channel shows.

## Known limitations

- **Not tried with a real Reolink camera yet.**
- A camera must record to an SD card or an NVR: its live stream isn't
  recorded by the streamer.
- A streamer off for more than a week misses the older recordings.
- Up to 16 cameras per streamer, Blink's, GoPro's and Reolink's together
  (the auth API's limit).
