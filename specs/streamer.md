# Streamer (`presence-streamer`)

[presence_streamer/](../presence_streamer) is a command-line app (Go) that
makes a **Raspberry Pi** with a camera a Presence camera for a **Premium**
profile, with no screen. It records continuously and uploads every chunk.
Chunks with a person or an animal in them become events in the profile,
as a phone's motion clips do. The rest are deleted. It runs on Raspberry Pi
OS **32-bit (armhf)** and **64-bit (arm64)**, Bookworm or newer, on every Pi
from the Zero to the 5. The [Raspberry Pi camera](raspberry-pi.md) `.deb`
(the web app in a kiosk) is the other way to make a Pi a camera.

Not yet: [live sync](live-sync.md) (MQTT). The streamer doesn't connect to
it, publish its events there or answer presence pings, as a phone does.
Its events reach the profile's devices from the bucket, within their next
sync pass (15 s). That comes next, once streaming is tested on a Pi.

## Installing it

On the Pi, one command installs the right `.deb` and sets it up for the
profile; the service then starts at every boot:

```sh
curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- <profile ID>
```

The app's account sheet shows it, with the profile filled in and a **Copy
command** button, for a premium profile. See [Install
script](install-script.md#streamer).

## Starting it

`presence-streamer` (or `presence-streamer run`) streams.
`presence-streamer setup` does everything before the streaming and exits:

1. **The profile ID.** On a terminal it **asks for it at every start**
   (`Presence profile ID [<saved>]:`, Enter keeps the saved one). Without a
   terminal (the service), it takes `--profile` / `PRESENCE_STREAMER_PROFILE`,
   else the saved one. It must look like a profile ID (`a_b_c`, at most 64).
   Another profile than the saved one forgets the saved sign-in.
2. **A Google sign-in**, the first time: Google's **device flow**. It shows
   a URL (google.com/device) and a code that someone enters on a phone or
   computer, with an account of that profile. The scope is `openid email`.
   The refresh token is kept, so later starts (and the service) need no one.
3. **Checks**, before the sign-in is kept and at every renewal:
   - `GET /api/auth/profile` with the ID token must answer the **profile
     asked for**. Otherwise it stops: "this Google account's profile is X,
     not Y". **A profile ID alone grants nothing**, since only an account of
     the profile can sign in to it.
   - `POST /api/auth/credentials` (the device ID as the body, so the device
     joins the profile's [devices](premium.md#devices)) must say `"tier":
     "premium"`. **A free profile ends it** (exit 3), at the start or whenever
     it turns free later. The service doesn't restart it.
4. Cognito's `GetCredentialsForIdentity` trades the answer's token for AWS
   credentials for the profile's folder, as the app does ([Cloud
   sync](cloud-sync.md)). They're renewed 5 minutes before they expire
   (hourly), going through steps 2 and 3 again.

- **Run as root**, `setup`, `status` and `sign-out` run again as the
  package's `presence-streamer` user (`runuser`), so the state is the
  service's. After `setup`, it enables and (re)starts the service. After
  `sign-out`, it stops it. `run` as root, with the package installed, is
  refused (exit 2): the service runs it, and root's files in its folder
  would lock the service out.
- **One streamer per state folder:** it holds a lock (`flock` on `lock`
  there) while it runs, and a second one exits 2.
- `presence-streamer status` shows the profile, device, account and state
  folder. `sign-out` forgets the refresh token. `version` shows the version
  and architecture.
- **Exit codes:** 0 stopped, 1 an error (retried by the service), 2 not set
  up or wrong usage (including a sign-in that's revoked, refused by the auth
  API, or another profile's: trying again wouldn't help), 3 a free profile.
  The service doesn't restart for 2 or 3.
- **What the auth API answers is checked** before use: the identity ID
  (`<region>:<uuid>`, which names Cognito's host and the folder) and the
  bucket's name (S3's rules), since both go into URLs and rclone paths.

## State

One file, `state.json` (mode 600, in a 700 folder), in the state folder:
`/var/lib/presence-streamer` for the package's user, else
`$XDG_STATE_HOME/presence-streamer` (`~/.local/state/…`). It holds:

- the **device ID** (`adjective_adjective_thing`, from the app's word
  lists, kept in step by a test);
- the **media key**, made once with it (32 random bytes), as a phone
  makes its own ([Media encryption](encryption.md));
- the profile, the refresh token and the account's email.

The spool (`spool/`) and an empty `rclone.conf` (so the user's rclone
remotes never apply) are beside it.

## Recording

`recorder` package. **Source** (`--source`): `auto` takes the camera module
when libcamera lists one (`rpicam-vid --list-cameras`, or `libcamera-vid`
on older systems), else a USB camera (`v4l2`, `/dev/video0`). `test` is
ffmpeg's test pattern, or a video file played in a loop (`--device`), for
development. **Encoder** (`--encoder`): `auto` takes the Pi's **hardware
H.264 encoder** when there is one (the bcm2835 codec's encode device, on a
Pi 4 and earlier), else libx264. A Pi 5 has no encoder.

| Source, encoder | Commands |
|---|---|
| camera module, hw | `rpicam-vid --codec h264 --inline --intra <fps> --bitrate … -o -` piped into `ffmpeg -f h264 -c:v copy` |
| camera module, sw (Pi 5) | `rpicam-vid --codec yuv420 -o -` into `ffmpeg -f rawvideo … -c:v libx264` |
| USB, hw | `ffmpeg -f v4l2 … -c:v h264_v4l2m2m -g <fps>` |
| USB, sw | `ffmpeg -f v4l2 … -c:v libx264 -preset veryfast -tune zerolatency -g <fps>` |

- **1280×720 at 30 fps, 2.5 Mbit/s**, a keyframe every second, no audio
  (camera modules have no microphone), all settable. `--rotation 180` for
  an upside-down camera module.
- **Chunks:** ffmpeg's segment muxer cuts the stream at keyframes into MP4
  files (`+faststart`) of `--chunk` (30 s, 10 s to 5 min) in the spool,
  named by their run and **UTC start**: `rec-<run>-20261011T143345.mp4`
  (ffmpeg runs with `TZ=UTC`; the run is new each time ffmpeg starts, so a
  clock gone back can't reuse a name). The time is the event's.
- **Finished chunks** (`recorder.Segments`) are the ones ffmpeg lists as
  done in its segment list (`segments-<run>.csv`) and those there before it
  started; every one while it isn't running. They're taken oldest first by
  when they were written, so a clock gone back doesn't reorder them or make
  the one being written look finished.
- **Restarts:** when the recorder stops it's started again after 2 s,
  doubling to a minute while it keeps failing. On a stop, ffmpeg gets
  SIGINT and finishes its chunk.
- **The clock:** a Pi has none of its own, and after a boot it says the
  time it was shut down (fake-hwclock) until the network sets it. It waits
  for systemd's time sync (`/run/systemd/timesync/synchronized`, or
  `timedatectl`'s `NTPSynchronized`) up to 2 minutes, then records anyway
  (a Pi offline still records, its chunks named by its clock). It always
  waits for the clock to say 2026 or later.

## Each chunk

`stream` package. Finished chunks are taken oldest first, one at a time
(every 2 s while there are none):

1. **Broken** (ffprobe ran and couldn't read it, e.g. cut by a power cut):
   deleted, if it isn't ingested yet. ffprobe cancelled, killed or missing
   isn't the chunk's fault: it's tried again. Its length is kept with its
   progress, so it's probed once.
2. **Sealed** with the device's key, in the app's format ([Media
   encryption](encryption.md#sealed-format); the app's test
   `streamer_seal_test.dart` opens the streamer's fixture), and **uploaded
   to ingest**: `<identityId>/ingest/<deviceId>/<clipId>.mp4`. The clip ID
   (and the event ID) are made like the app's (`AppEvent.newId`), from the
   chunk's start. The sealed copy is kept until the chunk is stored or
   deleted.
3. **Searched:** ffmpeg decodes only its **keyframes** (`-skip_frame
   nokey`, one a second, as on Android), at most 1280 px wide, to JPEGs. The
   detector looks at each:
   - `presence-detect.py`, kept running (started again if it dies), with
     **YOLOv4-tiny** (COCO's 80 classes, 416 px) through **OpenCV's DNN
     module**. Debian and Raspberry Pi OS package it as `python3-opencv`
     (4.6 on Bookworm, 4.10 on Trixie) for armhf and arm64. OpenCV 5 dropped
     darknet models, so it needs OpenCV 4.
   - Labels are the app's (`cocoLabels`: people are `human`). Each label
     gets its best score (0.4 or more) and the time of that frame.
   - The **subject** is the best person or animal (human, bird, cat, dog,
     horse, sheep, cow, elephant, bear, zebra, giraffe) scoring **0.5** or
     more, as the app's subjects. Its frame, at most 640 px wide, is the
     thumbnail.
4. **No subject:** deleted, from ingest and the spool.
5. **A subject:** stored as a phone stores a motion clip:
   - the thumbnail, sealed, to `media/<clipId>.jpg`;
   - the recording **moved** (a server-side copy and delete) from ingest to
     `media/<clipId>.mp4`. If the move fails (it was moved already, before
     a crash kept that from being noted), the sealed copy is uploaded there
     instead, and ingest's deleted;
   - the clip record, `clips/year=…/day=…/<clipId>.json`: no before part,
     `afterMs` and `full` (`<clipId>-full`, `video/mp4`, 0 to its length)
     the chunk's length, `complete`;
   - last, the event, `events/year=…/day=…/<eventId>.json`: a
     `clip_requested` event with `trigger: motion` ("Motion detected"),
     `detail` the camera's name, `cameraId` its source, the device, user
     (the account's Google ID), profile, `os: Linux`, the location set
     with `--location lat,lng` (`source: map`) or none, and its
     **`objectTags`**: the labels scoring 0.6 or more (the app's object tag
     score), plus the subject's. A clip with a person or pet nobody named
     shows the app's yellow **unidentified** flag, with **Identify**.
   - All JSON is compact and one line; media is `application/octet-stream`
     and JSON `application/json`, in Intelligent-Tiering, as single PUTs
     ([Recording and data formats](data-formats.md)).
6. **Its progress** is kept beside it (`<chunk>.json`: the IDs, whether
   it's ingested, the detector's answer, each upload done). A chunk
   interrupted by a restart or the network carries on where it was, with
   the same IDs, and nothing is uploaded twice.
- **Failures** (the network, AWS): the chunk stays and is tried again
  after 5 s, doubling to 2 min. A chunk whose search fails **3 times**
  (ffmpeg can't decode its keyframes, the detector fails or dies on it) is
  given up, deleted, so it doesn't hold up the chunks after it; a detector
  that doesn't start at all (OpenCV or the models missing) gives up
  nothing. On a stop, the detector is killed at once. Chunks wait in the spool meanwhile, up to
  `--spool-max-mb` (2 GB). Past that, the oldest are deleted unsent.
- **The device's settings** (`devices/<deviceId>/settings.json`: its ID,
  profile, `config: {"version": 1}`, location and **`mediaKey`**) go up at
  each start, retried until they're there. The profile's other devices read
  the key there to open its thumbnails and recordings.

## Uploads (rclone)

`rclone` package: `rclone copyto`, `moveto` and `deletefile` on an
on-the-fly S3 remote, `:s3:<bucket>/<identityId>/<key>`.

- **Credentials** go in the environment (`RCLONE_S3_ACCESS_KEY_ID`,
  `_SECRET_ACCESS_KEY`, `_SESSION_TOKEN`), never on the command line, and
  are fetched for each command (current, renewed as above).
- `--s3-no-check-bucket` and `--s3-no-head` (the role may only put, get,
  delete and list in its folder), `RCLONE_S3_STORAGE_CLASS=INTELLIGENT_TIERING`,
  `RCLONE_S3_UPLOAD_CUTOFF=5G` (single PUTs: an object's ETag is its MD5,
  which the app's sync relies on), `--bwlimit` from `--bwlimit`.
- **The bucket** is the credentials answer's `bucket` (the auth API names
  it; see [Auth API](auth-api.md)), or `--bucket`. `--s3-endpoint` points at
  another S3 (tests).

## The `ingest/` prefix

`<identityId>/ingest/<deviceId>/` holds sealed chunks only while they're
searched: each is moved to `media/` or deleted within moments. The app
never lists it ([Cloud sync](cloud-sync.md) reads `events/`, `clips/`,
`media/` and `devices/`). What a crash or a failed delete leaves expires
with the bucket's 90-day lifecycle. The profile's role already allows its
whole folder, so it needed no infrastructure change.

## Package and builds

[scripts/streamer.sh](../scripts/streamer.sh) (`make streamer`) builds,
into `presence_streamer/build/`:

- `presence-streamer_<version>_armhf.tar.gz` and `_arm64.tar.gz`: the
  binary, `presence-detect.py`, `models/` and the README, which run as they
  are (the binary looks for the detector and models beside itself first);
- with `dpkg-deb`, `presence-streamer_<version>_armhf.deb` and `_arm64.deb`.

Details:

- **Go, cross-compiled, static** (`CGO_ENABLED=0`, `-trimpath`): armhf is
  `GOARM=6`, since Raspberry Pi OS 32-bit is ARMv6 hard-float, so one binary
  runs on every Pi. arm64 is `GOARCH=arm64`. No Go dependencies beyond the
  standard library.
- **The model** (darknet's `yolov4-tiny.cfg` at a pinned commit and
  `yolov4-tiny.weights`, 24 MB, YOLO license) is downloaded at build time
  and checked against its SHA-256; it isn't in the repository.
- **The version** is the app's ([Versioning](release.md#versioning)), and
  `-X main.version`.
- **The Google client** for the device sign-in (`GOOGLE_DEVICE_CLIENT_ID`,
  `GOOGLE_DEVICE_CLIENT_SECRET`, from the environment or `.env`) is built
  in with `-X`. It must be a **"TVs and Limited Input devices"** OAuth
  client, the only kind Google's device flow takes. Google doesn't treat
  its secret as confidential (it ships in the binary). A build without
  it needs `PRESENCE_STREAMER_GOOGLE_CLIENT_ID` and `_SECRET` at run time.

**The `.deb`** (`packaging/streamer/`):

| Path | What |
|---|---|
| `/usr/bin/presence-streamer` | the binary |
| `/usr/lib/presence-streamer/presence-detect.py` | the detector |
| `/usr/share/presence-streamer/models/` | the model |
| `/lib/systemd/system/presence-streamer.service` | the service |
| `/etc/default/presence-streamer` | settings, `PRESENCE_STREAMER_*` (conffile) |
| `/var/lib/presence-streamer/` | the state and spool (the user's home, 700) |

- **Depends:** `adduser`, `ffmpeg (>= 7:5.1)`, `rclone`, `python3`,
  `python3-opencv`, `python3-numpy`, all from Debian / Raspberry Pi OS for
  both architectures. **Recommends:** `rpicam-apps | libcamera-apps`.
- **postinst** makes the `presence-streamer` system user (groups `video`
  and `render`, for the camera and the encoder) and its folder, and
  **enables the service for every boot**. On an upgrade, it restarts it if
  it's set up. Until it's set up, the service stops at once (exit 2) and
  isn't restarted: `sudo presence-streamer setup` starts it.
  **prerm** (remove) stops and disables it. **postrm** (purge) deletes the
  state (key, sign-in, spool). The user stays, as Debian does.
- **The service** runs `presence-streamer run` as that user, with the
  settings file, `Restart=always` (10 s), `RestartPreventExitStatus=2 3`,
  `Nice=5`, after `network-online.target`. Its groups come from
  `/etc/group` (no `SupplementaryGroups=`: a group a system lacks, such as
  `render`, would fail the unit). Hardening: `NoNewPrivileges`,
  `ProtectSystem=strict` (writes only its state folder), `ProtectHome`,
  `PrivateTmp`, kernel and control-group protections,
  `CapabilityBoundingSet=` (none), `SystemCallFilter=~@clock @module @mount
  @reboot @swap`, `RestrictNamespaces`, `RestrictSUIDSGID`,
  `RestrictRealtime`, `LockPersonality`, `RestrictAddressFamilies` (Unix,
  IP, netlink), `UMask=0077`; `systemd-analyze security` rates it 2.5 (OK).
  Not `PrivateDevices`, `DeviceAllow` or **`ProtectClock`**, which implies
  `DeviceAllow=char-rtc r` and so a device allowlist: any of them would
  shut out the camera, the encoder and the DMA heaps (found in review).

**Releases** ([Release builds](release.md)): the Release workflow's
`streamer` job (ubuntu-latest, Go from `go.mod` with `actions/setup-go`)
runs the unit tests and `make streamer`, and uploads
`presence-streamer-<tag>-linux-armhf.tar.gz`, `-linux-arm64.tar.gz`,
`presence-streamer-<tag>-raspberrypi-armhf.deb` and `-raspberrypi-arm64.deb`.

## Settings

Every flag is also `PRESENCE_STREAMER_<NAME>` (the service reads them from
`/etc/default/presence-streamer`): `profile`, `api`
(https://presence.nu01.com; https://rc.presence.nu01.com for the RC),
`bucket`, `s3-endpoint`, `source`, `device`, `encoder`, `width`, `height`,
`fps`, `bitrate`, `rotation`, `chunk`, `spool-max-mb`, `bwlimit`,
`camera-label`, `location`, `detector-threads`, `state-dir`, the tools'
paths (`python`, `rclone`, `ffmpeg`, `ffprobe`, `rpicam-vid`, `detector`,
`models`) and the Google client.

## Infrastructure it needs

- **A Google OAuth client** of type "TVs and Limited Input devices", in the
  same Google Cloud project as the web client. Its ID goes in the
  repository variable `GOOGLE_DEVICE_CLIENT_ID` and its secret in the secret
  `GOOGLE_DEVICE_CLIENT_SECRET`, for the release builds. Until it exists,
  the released streamer can't sign in.
- **The auth API accepts its ID tokens:** the JWT authorizer's audiences
  are the web client and `GoogleDeviceClientId` (from
  `GOOGLE_DEVICE_CLIENT_ID`, passed by `scripts/deploy.sh` and the deploy
  workflows), when set ([Auth API](auth-api.md)). The tokens carry the same
  Google `sub`, so the same account finds the same profile.
- **The credentials answer names the bucket** (`bucket`).
- The identity pool trusts only the web client's Google tokens, so a
  profile's Cognito identity must have been made by the app (its first
  credentials) before the streamer's first call. It always has: the
  profile ID comes from the app's account sheet.

## Verified

- Unit tests (`go test ./...` in `presence_streamer/`):
  - **seal:** every size, broken objects, and a fixture the app's
    `streamer_seal_test.dart` opens with `SealFormat`;
  - **IDs:** the app's word lists;
  - **records:** the JSON and keys, day partitions;
  - **Google:** the device flow against a fake;
  - **API and session:** auth API and Cognito clients, renewal before
    expiry, a free profile and another profile fatal;
  - **recorder:** each source and encoder's commands, chunk names, finished
    chunks from ffmpeg's segment list (a clock gone back included), and real
    1 s chunks from ffmpeg's test pattern, never the one being written;
  - **detect:** the detector process, restarted after it dies, and
    keyframe extraction;
  - **rclone:** secrets only in the environment, and put, move and delete
    against `rclone serve s3`;
  - **stream:** an empty chunk deleted; a subject stored as a phone would,
    in order, with sealed media that opens; resuming after a failure at
    each step without uploading twice; a failed move uploading the sealed
    copy; a search failing 3 times given up, but not a detector that's
    down; a broken chunk deleted, a cancelled probe not; the spool cap; the
    settings' key;
  - **state:** the lock against a second streamer;
  - **auth API:** `ProfileTest` (the bucket in the answer).
- **End to end** (`main_e2e_test.go`): a video (10 s of nothing, 10 s of a
  person) as the camera, through the real recorder, ffmpeg, detector and
  rclone into `rclone serve s3`, with Google and the auth API faked. The
  empty chunks were deleted. The ones with the person became events
  (`human` 0.99–1.00, with `dog` and `horse` from the photo), their
  recording and thumbnail opened with the device's key, ingest was empty
  after, and the settings carried the key. Passed on macOS (OpenCV 4.10).
- **On 32- and 64-bit ARM** (Docker, emulated), the .deb installed from
  Debian's archive with its dependencies:
  - **Debian 13 Trixie arm64:** ffmpeg 7.1, rclone 1.60, OpenCV 4.10. The
    user (`video` group), its 700 folder and the boot link
    (`multi-user.target.wants`) were made; the detector found the person and
    the dog with Debian's OpenCV; `status` as root ran as the service user.
  - **Debian 12 Bookworm armhf** (32-bit, emulated): ffmpeg 5.1, rclone
    1.60, OpenCV 4.6, the same checks.
  - On both, `run` as root refused (exit 2), and the end-to-end test above,
    cross-compiled for each architecture (GOARM=6 for armhf), with
    Debian's ffmpeg, rclone and OpenCV: 3 minutes of chunks, every empty
    one deleted, every one with the person stored.
  - Purge deleted the state and the boot link.
- **Reviewed** (correctness and security) before the first commit: the
  review found `ProtectClock` shutting out the camera, a hang when the
  recorder couldn't start, chunks mistaken for finished when the clock
  went back, chunks deleted on a cancelled probe, a stuck chunk holding up
  the rest, root's `run` locking out the service, slow stops, and the auth
  API's answers going unchecked into URLs. All fixed, with tests.
- **Not yet on a real Raspberry Pi:** the camera module through
  `rpicam-vid`, the hardware encoder, USB cameras, systemd at boot, a
  real Google device sign-in and the real bucket (which need the OAuth
  client above).

## Known limitations

- **No live sync** (above): events reach the other devices from the bucket
  within 15 s, not within a second, and the streamer doesn't show as
  present.
- **Unattended sign-in lasts as long as Google's refresh token.** An OAuth
  app in Google's "Testing" status has its refresh tokens expire after 7
  days: publish it. A revoked or expired one stops the streamer (exit 2)
  until `setup` runs again.
- **A chunk is the clip:** a subject at the very end of one chunk and the
  start of the next makes two events.
- **No audio.**
- **The detector is slow on a Pi Zero** (seconds a frame). Chunks queue
  in the spool while it catches up, up to its cap.
- **The SD card is written continuously** (the spool). `--state-dir` (or
  `PRESENCE_STREAMER_STATE_DIR`) on another disk or a tmpfs spares it.
- **No subject recognition** (who it is): only object detection. The app's
  **Auto**, or the profile's [cloud recognition](cloud-recognition.md),
  names them.
- Chunks are stored whole (up to 30 s), not cut to the subject.
