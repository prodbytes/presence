# Streamer (`presence-streamer`)

[presence_streamer/](../presence_streamer) is a command-line app (Go) that
makes a **Raspberry Pi** with a camera a Presence camera for a **Premium**
profile, with no screen. It records continuously and uploads every chunk.
Chunks with a person or an animal in them become events in the profile,
as a phone's motion clips do. The rest are deleted. It runs on Raspberry Pi
OS **32-bit (armhf)** and **64-bit (arm64)**, Bookworm or newer, on every Pi
from the Zero to the 5. The [Raspberry Pi camera](raspberry-pi.md) `.deb`
(the web app in a kiosk) is the other way to make a Pi a camera.

**One streamer streams per profile:** the leader, which the auth API
grants, preferring the one with the most memory. The others wait until a
leader offline for an hour (or deleted) leaves them its place. See
[Streamer leadership](streamer-leader.md).

While it leads, the streamer is on [live sync](live-sync.md) (MQTT, AWS
IoT Core) as an always-connected device: each event it stores reaches the
profile's devices within a second, and it answers [device
presence](device-presence.md)'s pings, so it shows live. See **Live
sync** below.

## Installing it

On the Pi, one command installs the right `.deb` and sets it up as a new
device of the profile, with no sign-in (so a Pi without a screen or
keyboard works, over SSH or not); the service then starts at every boot:

```sh
curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- \
  --profile <profile ID> --device-id <device ID> --key <stream key>
```

The app's account sheet makes it: **Create command** in the **Stream from
a Raspberry Pi** box, for a premium profile, then **Copy command**. See
[Install script](install-script.md#streamer). The older form, with only
the profile ID and a Google sign-in, still works (below).

## The stream key

A device's **stream key** (`psk_` and 32 random bytes, base64url) lets the
streamer get its profile's credentials with no Google account:

- **Made by the app** (`POST /api/auth/profile/stream-key`, the device ID
  as the body, with a member's [session token](sessions.md)): a new device ID
  (`DeviceId.generate`) and its key, replacing any key that device had.
  The auth API keeps only the key's SHA-256, with who made it (email and
  the sign-in's subject, `idp_sub`: the Google `sub` for a Google account)
  and when, in `StreamKeysTable`. It also makes sure the profile has its
  Cognito identity, linked to the profile, before the streamer asks. The key is shown once, in the command. Every key of
  a profile is deleted with it when its owner deletes their account
  ([Account deletion](account-deletion.md)).
- **Used by the streamer** (`POST /api/auth/stream/credentials`, no
  authorizer: `Authorization: Bearer <key>`, the body `<profile ID>
  <device ID> [<camera device ID>...]`: the IDs after its own are the
  cameras it streams for, its [Blink](blink.md), [GoPro](gopro.md) and
  [Reolink](reolink.md) cameras, up to 16, which join the profile's
  devices too): when the key's hash is that device's (compared in
  constant time), the auth API answers as `POST /api/auth/credentials`
  does for that device (which joins the profile's devices), tiered by the
  profile owner's roles in rbacr, plus `userId`, the `sub` of who made the
  key (the events' `userId`). Anything else is the same 401. Throttled to
  2 requests/s (burst 10). **Only the profile's leading streamer** gets
  them: another gets 409 (`"reason": "notLeader"`) and waits, asking `POST
  /api/auth/stream/lease` ([Streamer leadership](streamer-leader.md)).
- **Revoked** when the device is deleted in the app
  ([Device deletion](device-deletion.md); `POST
  /api/auth/profile/devices/remove` deletes its key), or replaced by a new
  command for the same device. The streamer then stops (exit 2): "the
  auth API refused the stream key: copy a new command from the app's
  profile view".
- **On the Pi** it's in the state file (mode 600, the service user's),
  never logged. It's on the command line while setup runs.

## Starting it

`presence-streamer` (or `presence-streamer run`) streams, once it leads
the profile's streamers; until then it waits, asking every 5 minutes
([Streamer leadership](streamer-leader.md)).
`presence-streamer setup` does everything before the streaming and exits
(a key whose streamer would wait is still ready).

**With a stream key** (`--profile`, `--device-id` and `--key`, or
`PRESENCE_STREAMER_PROFILE`, `_DEVICE_ID`, `_KEY`), as the app's command
runs it: it checks the key with the auth API (the device's key, a premium
profile), then keeps the profile, the device ID (instead of the one it
made) and the key, and needs no terminal. Every start, and every renewal
of the credentials (hourly), asks `POST /api/auth/stream/credentials`
again. A refused key or a free profile stops it (exit 2 or 3).
**Streamers are Premium's (and Pro's), enforced by the auth API:** it
makes stream keys only for a premium member (403 otherwise), and answers
`POST /api/auth/stream/credentials` with **403** and no token when the
profile's owner isn't premium, or when the streamer is past the plan's
device limit ([Plans](premium.md#devices)); before, a free owner's
profile got a `"tier": "free"` token, which the streamer turned down
itself. presence-streamer reads those 403s (from the credentials or the
lease routes), at the start and at every renewal or lease request (one
mid-run ends the run, as a free tier does):
- `{"error": "streamers are Premium only"}` is a **free profile**:
  exit 3 ("this profile is free: …").
- `"reason": "deviceLimit"` is a **device past the plan's limit**: exit 2
  ("the auth API refused this device: … remove a device in the app, or
  upgrade the plan"). Trying again wouldn't help until someone does.
- Any other 403, and 5xx, is an error that passes: retried in the run,
  exit 1 at the start (the service restarts it).
Neither 3 nor 2 is restarted by the service, so a free or full profile's
Pi doesn't call the auth API every 10 seconds.

**With a Google sign-in** (no key):

1. **The profile ID**, never asked:
   - `PRESENCE_STREAMER_PROFILE` (the environment, set before it runs) or
     `--profile`, else the one saved;
   - **with none, the signed-in account's own:** after the sign-in (2) it
     asks `GET /api/auth/profile` and keeps that one ("This account's
     profile is …").
   It must look like a profile ID (`a_b_c`, at most 64). Another profile
   than the saved one forgets the saved sign-in.
2. **A Google sign-in**, the first time: Google's **device flow**. It shows
   a URL (google.com/device) and a code that someone enters on a phone or
   computer, with an account of that profile. The scope is `openid email`.
   The refresh token is kept, so later starts (and the service) need no one.
   Each Google ID token is exchanged for a Presence
   [session token](sessions.md) (`POST /api/auth/session`, `"refresh":
   false`: no Presence refresh token), kept until a minute before it
   expires; the calls below carry that, since the auth API takes no
   Google tokens.
3. **Checks**, before the sign-in is kept and at every renewal:
   - `GET /api/auth/profile` with the session token must answer the **profile
     given** (when one was). Otherwise it stops: "this Google account's profile is X,
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
  API, or another profile's, a refused stream key, or a device past the
  plan's limit: trying again wouldn't help), 3 a free profile (a free tier
  or the auth API's Premium-only 403).
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
development. The events name the camera (`--camera-label`), by default
"Streamer camera", "USB camera" or "Test camera". **Encoder** (`--encoder`): `auto` takes the Pi's **hardware
H.264 encoder** when there is one (the bcm2835 codec's encode device, on a
Pi 4 and earlier), else libx264. A Pi 5 has no encoder.

| Source, encoder | Commands |
|---|---|
| camera module, hw | `rpicam-vid --codec libav --libav-format mpegts --libav-video-codec h264_v4l2m2m --intra <fps> --bitrate … -o -` piped into `ffmpeg -f mpegts -c:v copy` |
| camera module, sw (Pi 5) | the same with `--libav-video-codec libx264` |
| USB, hw | `ffmpeg -f v4l2 … -c:v h264_v4l2m2m -g <fps>` |
| USB, sw | `ffmpeg -f v4l2 … -c:v libx264 -preset veryfast -tune zerolatency -g <fps>` |

- **1280×720 at 15 fps, 2.5 Mbit/s**, a keyframe every second, no audio.
  15, not 30, since a frame's exposure is capped at 1/fps: measured on a
  Pi Zero in a dim room, 15 fps gave twice the light (mean luma 19 against
  10). `--fps` still sets it
  (camera modules have no microphone), all settable. `--rotation 180` for
  an upside-down camera module.
- **MPEG-TS from the camera module**, not raw H.264. It carries each
  frame's real time. A Pi that can't keep up the frame rate still makes
  chunks as long as the time they cover: a Zero makes about 23 fps at 720p.
  With raw H.264, ffmpeg assumed 30 fps, so an 8 s recording became a 5.8 s
  video. That was found on the Pi Zero.
- **Chunks:** ffmpeg's segment muxer cuts the stream at keyframes into MP4
  files (`+faststart`) of `--chunk` (30 s, 10 s to 5 min) in the spool,
  named by their run and **UTC start**: `rec-<run>-20261011T143345.mp4`
  (ffmpeg runs with `TZ=UTC`; the run is new each time ffmpeg starts, so a
  clock gone back can't reuse a name). The time is the event's.
- **Finished chunks** (`recorder.Segments`) are the ones ffmpeg lists as
  done in its segment list (`segments-<run>.csv`, read a whole line at a
  time as it grows; what's been processed is forgotten) and those there
  before it started; every one while it isn't running. The list's start and end
  times give each chunk's length, so ffprobe (about 4 s a chunk on a Pi Zero)
  runs only for a chunk from an earlier run. They're taken oldest first by
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

1. **No motion: deleted here, before anything is uploaded**, which spares
   S3's storage and requests:
   - The motion is the app's motion score ([Motion clips](motion-clips.md)):
     the percentage of a 64×48 grayscale frame's pixels whose brightness
     changed by more than a step, after the median change (exposure, a light
     switched on) is taken off.
   - It's scored between consecutive **keyframes** (one a second), which
     ffmpeg decodes alone (`-skip_frame nokey`, scaled to 64×48 gray), in
     one pass, cheap even on a Pi Zero.
   - **The step follows the light:** a quarter of the two frames' mean
     luma, from 4 to the app's 24/255. Lit scenes (mean 96 or more) keep
     24; a dim room's (mean 10) is 4, where someone crossing changes few
     pixels by 24. Measured on a Pi Zero's camera at night: a still
     scene's keyframes moved at most 1.7 % with a step of 4 (4.5 % with
     3), and every chunk of someone walking past scored under 1 % with 24.
   - The chunk's motion is its highest score. At **5 % or less**
     (`--motion-min`, `PRESENCE_STREAMER_MOTION_MIN`; 0 keeps every chunk)
     it's deleted: "no motion (0.0%), deleted".
   - A chunk with one keyframe has nothing to compare, so it's kept.
   - A chunk ffmpeg can't read is broken (next).
   - Done once per chunk: the score is kept with its progress.
2. **Broken** (ffprobe or ffmpeg ran and couldn't read it, e.g. cut by a power cut):
   deleted, if it isn't ingested yet. ffprobe cancelled, killed or missing
   isn't the chunk's fault: it's tried again. Its length is kept with its
   progress, so it's probed once.
3. **Sealed** with the device's key, in the app's format ([Media
   encryption](encryption.md#sealed-format); the app's test
   `streamer_seal_test.dart` opens the streamer's fixture), and **uploaded
   to ingest**: `<identityId>/ingest/<deviceId>/<clipId>.mp4`. The clip ID
   (and the event ID) are made like the app's (`AppEvent.newId`), from the
   chunk's start. The sealed copy is kept until the recording is verified
   in `media/` (or, in the cloud's mode, in ingest), or the chunk is
   deleted.
4. **Searched** (here, with 2 GB of memory or more; else see [Cloud detection](#cloud-detection)): ffmpeg decodes only its **keyframes** (`-skip_frame
   nokey`, one a second, as on Android), at most 1280 px wide, to JPEGs. The
   detector looks at each:
   - `presence-detect.py`, kept running (started again if it dies), with
     **YOLOv4-tiny** (COCO's 80 classes, 416 px) on each frame
     **brightened when it's dark** (mean luma under 70: a gamma curve to a
     mean of about 110, then CLAHE on its lightness; on 54 cat photos
     darkened to a dim room's level it found 22 subjects where the dark
     ones gave 14 and full light 23; the Pi's detector and the cloud's
     the same), through **OpenCV's DNN
     module**. Debian and Raspberry Pi OS package it as `python3-opencv`
     (4.6 on Bookworm, 4.10 on Trixie) for armhf and arm64. OpenCV 5 dropped
     darknet models, so it needs OpenCV 4.
   - Labels are the app's (`cocoLabels`: people are `human`). Each label
     gets its best score (0.4 or more) and the time of that frame.
   - The **subject** is the best person or animal (human, bird, cat, dog,
     horse, sheep, cow, elephant, bear, zebra, giraffe) scoring **0.5** or
     more, as the app's subjects. Its frame, at most 640 px wide, is the
     thumbnail.
5. **No subject:** deleted, from ingest and the spool.
6. **A subject:** stored as a phone stores a motion clip:
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
7. **Its progress** is kept beside it (`<chunk>.json`: the IDs, whether
   it's ingested, the detector's answer, each upload done, the event's or
   the job's last). A chunk interrupted by a restart or the network
   carries on where it was, with the same IDs, and nothing is uploaded
   twice: one stopped after its last upload, before it was deleted, is
   deleted at the next start without uploading anything again.
8. **Deleted from the device once verified in the bucket**, and not
   before: an upload or move counts only once it's verified by size and
   MD5 ([Uploads](#uploads-rclone)), and only then is what it was made
   from deleted here. The thumbnail (and its sealed copy) and each JSON
   record as soon as each is verified; the sealed copy
   once the recording is verified in `media/` (in the cloud's mode, in
   ingest); the chunk itself and its progress once the event (in the
   cloud's mode, the job) is verified, its last upload. The chunk stays
   till then: its search needs it, and it's what's picked up after a
   restart. An upload that fails verification is a failed upload: what it
   was for stays, and it's tried again as below. Only the chunks deleted
   above without being kept (no motion, broken, no subject, a search given
   up) and the spool's oldest past its cap go without an upload.
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
- `--s3-no-check-bucket` (the role may only put, get, delete and list in
  its folder: no bucket made or checked), `--s3-no-head` (no HEAD after an
  upload: its PUT's answer is checked instead), `--checksum`,
  `RCLONE_S3_STORAGE_CLASS=INTELLIGENT_TIERING`,
  `RCLONE_S3_UPLOAD_CUTOFF=5G` (single PUTs: an object's ETag is its MD5,
  which the app's sync relies on; the bucket's SSE-S3 encryption keeps it
  so), `--bwlimit` from `--bwlimit`.
- **Every upload and move is verified, by size and MD5**, before it
  succeeds, by rclone itself (1.60, Debian's and Raspberry Pi OS's, and
  later; read in its source, and tested against a fake S3):
  - **an upload** (`copyto`, one PUT) sends the file's MD5 as
    `Content-MD5`, so S3 refuses a body that doesn't match it, and
    compares the ETag the PUT answers (the object's MD5) with the file's:
    a difference fails it ("corrupted on transfer") and deletes the copy.
    The size is the PUT's `Content-Length`, which the MD5 covers. Each
    upload is a HEAD (is it there already?) and the PUT: an object already
    there with the same size and MD5 (`--checksum`) isn't uploaded again;
  - **a move** (`moveto`) copies server side, then HEADs the copy and
    compares its size and MD5 with the source's before it deletes the
    source.

  So verifying costs no request more than an upload did. A failed
  verification is a failed upload: the local files stay, and it's tried
  again with the chunk's backoff.
- **The bucket** is the credentials answer's `bucket` (the auth API names
  it; see [Auth API](auth-api.md)), or `--bucket`. `--s3-endpoint` points at
  another S3 (tests).

## Cloud detection

**On a Pi with less than 2 GB of memory**, searching on the device would
take too much of it. There the chunks are searched in the cloud instead:

- **Which:** `--detection` (`PRESENCE_STREAMER_DETECTION`). `auto` (the
  default) reads `MemTotal` in `/proc/meminfo`: under 1.5 GiB means the
  cloud. A 2 GB board reports a little under 2 GiB, a 1 GB one under 1
  GiB. `local` and `cloud` force it. The log says which, and why
  ("detection: in the cloud (427 MB of memory, less than 2 GB)").
- **On the Pi**, each chunk with motion is sealed and uploaded to ingest,
  then its **job**, `ingest/<deviceId>/<clipId>.ingest.json`:
  `{"v": 1, "event", "clip"}`, the clip record and event a phone would
  store, without object tags. The sealed copy is deleted once the chunk is
  verified in ingest, and the chunk once its job is: it's then **deleted
  from the device**. Nothing waits for the cloud's answer, and Python,
  OpenCV and the model aren't needed or started.
- **The device's key must be in the bucket first** (its settings,
  uploaded at start): the detector needs it to open the chunk. Until it
  is, chunks wait in the spool.
- **In the cloud:** the user-data bucket notifies **presence_ingest** (a
  Python 3.13 Lambda on arm64,
  [presence_ingest/](../presence_ingest/README.md)) of each job. That's
  S3's `ObjectCreated` with the suffix `.ingest.json`, so nothing it writes
  calls it again. It:
  1. reads the device's key from its settings;
  2. opens the chunk, checking it was sealed by that device;
  3. searches a frame a second with the same model, labels and thresholds
     as the Pi's detector (OpenCV 4.14);
  4. with **no one**, deletes the chunk and the job from S3;
  5. with **someone**, writes the sealed thumbnail (at most 640 px wide)
     to `media/<clipId>.jpg` and copies the recording to
     `media/<clipId>.mp4`. Then the clip record and, last, the event with
     its object tags (0.6 or more, plus the subject). Then it deletes
     ingest's copies and the job, last.

  Its deletes in ingest are **for good**: it deletes the version it read
  (or, for a chunk it didn't read, the current one), so ingest's passing
  copies aren't kept 30 days as old versions, the bucket's undo window for
  users' data. A newer upload of the same key, made since, is left to its
  own notification.
- **It trusts only the job's key.** The identity, device and clip come
  from the key (`<identity>/ingest/<device>/<clip>.ingest.json`, each
  checked by pattern). The job must agree with it: same clip and device, a
  `clip_requested` event, safe IDs, times between 2020 and 2100, and records
  that can be written. A job that doesn't is deleted with its chunk. It
  writes only in that identity's folder. Jobs are at most 64 KB, chunks
  256 MB.
- **A chunk is untrusted input:** any premium user can write their own
  ingest prefix, and their own devices' keys. So:
  - only an MP4 is opened (its `ftyp` box). OpenCV's FFmpeg may read only
    local files and only the MP4 demuxer
    (`OPENCV_FFMPEG_CAPTURE_OPTIONS`);
  - videos are at most 1920×1080, with at most 5 minutes at 60 fps
    decoded;
  - the search gives up 30 s before the function's 120 s timeout, and the
    chunk is deleted, not retried;
  - its files are in one work folder, emptied before each job, because a
    run killed mid-way leaves them and Lambda doesn't clear `/tmp`.
- **Retries:** each step can be done again. A job whose device's key isn't
  up yet fails and is retried (Lambda's default for S3's notifications:
  twice, within 6 hours; changing it needs
  `lambda:PutFunctionEventInvokeConfig`, which the deploy roles lack). One whose
  chunk is gone has its job deleted, and so does a broken one. What still
  fails stays in ingest until the bucket's lifecycle erases it (365 days; archived after 67).
- **The function** runs with 2048 MB, 120 s and 2 GB of `/tmp`. It has no
  reserved concurrency by default (`IngestConcurrency`, from
  `INGEST_CONCURRENCY` in `deploy.sh`, 0). The account's Lambda quota is
  10, and AWS keeps 10 unreserved, so none can be reserved until it's
  raised. Its role
  may get jobs, chunks and devices' settings, list the bucket (so a
  missing object answers 404), put `media/`, `clips/` and `events/`, and
  delete in `ingest/`, versions included (`s3:DeleteObjectVersion`, on
  `*/ingest/*` only), under the stage's permissions boundary. The package
  is 179 MB of Linux arm64 wheels (OpenCV, NumPy, cryptography) and the
  model, built by its Makefile whatever the machine.
- **Deploy:** `scripts/deploy.sh` downloads the model (`scripts/models.sh`,
  shared with the Pi's build, from
  `presence_streamer/detector/models.txt`) and deploys the user-data stack
  with the function it has. Then the `<prefix>-ingest` stack. Then the
  user-data stack again with `IngestFunctionArn`, its bucket notification:
  S3 needs the function's permission before it can notify it. The Deploy
  workflows set up Python 3.13 for its build.

## The `ingest/` prefix

`<identityId>/ingest/<deviceId>/` holds sealed chunks (and, in the cloud
mode, their jobs) only while they're searched: each is moved to `media/`
or deleted within moments. The app
never lists it ([Cloud sync](cloud-sync.md) reads `events/`, `clips/`,
`media/` and `devices/`). What a crash or a failed delete leaves expires
with the bucket's lifecycle (archived after 67 days, erased after 365). The profile's role already allows its
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
- **Live sync's IoT endpoint** (`IOT_ENDPOINT`, from the environment or
  `.env`, as the app's builds) is built in with `-X main.iotEndpoint`,
  only in AWS IoT's `<id>-ats.iot.<region>.amazonaws.com` form (another
  value, such as a local `.env`'s `ws://localhost:4566`, is left out with a
  warning). It's the account's `iot:Data-ATS` endpoint, one for prod and
  the RC (one AWS account): the stage tells them apart. A build without
  it has live sync off unless `PRESENCE_STREAMER_IOT_ENDPOINT` sets one.

**The `.deb`** (`packaging/streamer/`):

| Path | What |
|---|---|
| `/usr/bin/presence-streamer` | the binary |
| `/usr/lib/presence-streamer/presence-detect.py` | the detector |
| `/usr/share/presence-streamer/models/` | the model |
| `/lib/systemd/system/presence-streamer.service` | the service |
| `/etc/default/presence-streamer` | settings, `PRESENCE_STREAMER_*` (conffile) |
| `/var/lib/presence-streamer/` | the state and spool (the user's home, 700) |

- **Depends:** `adduser`, `ffmpeg (>= 7:5.1)`, `rclone`, from Debian /
  Raspberry Pi OS for both architectures. **Recommends:** `rpicam-apps |
  libcamera-apps`. **Suggests:** `python3`, `python3-opencv`,
  `python3-numpy`, needed only to search on the device. The install script
  adds them on a Pi with 2 GB or more; one under 2 GB searches in the
  cloud.
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
`fps`, `bitrate`, `rotation`, `chunk`, `motion-min` (5), `detection`
(`auto`), `spool-max-mb`, `bwlimit`, `iot-endpoint` (live sync's AWS IoT
endpoint: the build's, or `off`), `stage` (live sync's, `prod` or `rc`;
by default `rc` when `api` is the RC's `rc.` site, else `prod`),
`camera-label`, `location`, `detector-threads`, `state-dir`, `blink`
(`auto`, or `off`), `blink-every` (2m), `gopro` (`auto`, or `off`),
`gopro-video` (`low`, or `full`), `gopro-every` (2m), `reolink`
(`auto`, or `off`), `reolink-video` (`low`, or `full`), `reolink-every`
(2m), the tools'
paths (`python`, `rclone`, `ffmpeg`, `ffprobe`, `rpicam-vid`, `detector`,
`models`, `blink-helper`) and the Google client.

## Live sync

`internal/livesync` (with `internal/mqtt`, `internal/ws` and
`internal/sigv4`, standard library only), started by `streamCamera`
(`main_live.go`) while the streamer leads the profile, as the app's
`LiveSync` for an always-connected device (an admin's):

- **Connects** to `wss://<IoT endpoint>/mqtt`, presigned with SigV4
  (service `iotdevicegateway`, only `host` signed, valid 1 h, the session
  token appended after signing; the app's `presignWebSocket`, tested
  against the app's own vector), with the session's Cognito credentials
  (the same ones rclone uses), over TLS checked against the system's
  roots, subprotocol `mqtt`. MQTT 3.1.1, a **clean session**, client ID
  `<identityId>-<deviceId>-<session>` (six random `[a-z0-9]` per run, as
  the app's: the IoT policy allows only IDs that start with the
  identity), keep-alive 60 s (a PINGREQ every 45 s; a broker silent for
  90 s drops the connection).
- **Subscribes** (QoS 1) to the profile's `requests` topic only: it takes
  no other device's events or `copied` acks. A refused subscription is
  logged and leaves the connection up for publishing.
- **Publishes** each event it stores (its own camera's, and its Blink,
  GoPro and Reolink cameras'), once the event's JSON is verified in the
  bucket (`stream.Streamer.Publish`), on `events` at QoS 1, in the app's
  format: `v` 1, `kind` `event`, `deviceId` (the streamer's), `identityId`,
  `sentAt`, `key` (the event's object key), `etag` (the uploaded JSON's
  MD5, which is the object's ETag), `mediaKey` (the device's key, base64)
  and `event` (the record exactly as uploaded). No `clip`: a streamer's
  profile is premium, and premium devices take clips from the bucket. A
  message over 64 KB isn't sent. The broker's PUBACK isn't waited for.
- **Answers pings** on `requests` with a pong on `acks`
  (`{"v":1,"kind":"pong","deviceId","identityId","sentAt","nonce"}`, the
  ping's nonce), as a phone: not its own, not one older than 2 min by its
  `sentAt`, at most one pong every 5 s. Pings are checked as the app's
  `parsePresence` does (at most 1 KB, strict JSON, version 1, the
  identity, a safe device ID, an integer `sentAt`, a nonce of 8–64
  letters and digits); a malformed one is dropped and logged (the first,
  then every 100th). Another device's `sync` request (its Sync button) is
  ignored. Its Blink, GoPro and Reolink cameras don't answer: they show
  from their events.
- **Never holds up recording:** events wait in a queue of 100 that never
  blocks; more are dropped (logged), and the bucket carries them as
  before. Live sync runs in its own goroutine; a slow or stalled network
  only stalls it.
- **Reconnects** after a drop (1 s) and after a failed attempt (credentials,
  TLS, a refused handshake or CONNACK) with a back-off that doubles up to
  2 min, each attempt with fresh credentials and a newly signed URL, each
  step within 15 s; logged on the first failure of a streak and every
  tenth. **Renews** the connection 2 min before the credentials expire
  (the session renews them 5 min before). It stops with the streaming (a
  stop, or another streamer taking the lead).
- **Never logs a secret:** the URL (whose query holds the credentials) is
  never quoted, and any query in an error is cut (`?…`), as the app's
  `LiveSync.redact`.
- **Untrusted input:** WebSocket messages at most 256 KB (frames from the
  server must be unmasked, no text, extensions or reserved bits; control
  frames short and whole), the handshake answer at most 16 KB, MQTT
  packets at most 256 KB with strict parsing (QoS 2, wildcard or invalid
  topics, a 5-byte length, a zero packet ID drop the connection), and at
  most 64 received messages buffered.
- **Off** without an IoT endpoint (`iot-endpoint` empty or `off`), or with
  a wrong `stage`: it says so once at start, and streams as before.

## Blink cameras

A streamer the app's Settings pick also fetches a Blink account's
cameras' clips, each camera a device of its own: see
[Blink cameras](blink.md).

## GoPro and Reolink cameras

A streamer the app's Settings pick also fetches GoPro and Reolink cameras'
videos over its network, each camera a device of its own: see
[GoPro cameras](gopro.md) and [Reolink cameras](reolink.md). Both are
kinds of the `netcam` package (`main_netcams.go`), and Blink's, GoPro's
and Reolink's cameras share the per-camera pipelines (`main_cameras.go`).

## Infrastructure it needs

- **A Google OAuth client** of type "TVs and Limited Input devices", in the
  same Google Cloud project as the web client (`presence-492410`): client
  `104441697281-40fd6nuvjktdmpptc5tgnfu581gek22c` (since 2026-10-11). Its ID
  is the repository **variable** `GOOGLE_DEVICE_CLIENT_ID` and its secret the
  repository **secret** `GOOGLE_DEVICE_CLIENT_SECRET`, for the release
  builds and deploys. Locally both are in the private, git-ignored `.env`
  (mode 600), which `scripts/streamer.sh` and `scripts/deploy.sh` read; the
  secret is never committed. Checked against Google: it hands out device
  codes, and its token endpoint takes the secret (`authorization_pending`,
  not `invalid_client`). Builds and deploys from before it was set have no
  client: the next release and deploy carry it.
- **The auth API accepts its ID tokens:** the session exchange takes
  Google ID tokens issued for the web client or `GoogleDeviceClientId`
  (from `GOOGLE_DEVICE_CLIENT_ID`, passed by `scripts/deploy.sh` and the
  deploy workflows), when set ([Sessions](sessions.md)). The tokens carry
  the same Google `sub`, so the same account finds the same profile.
- **The credentials answer names the bucket** (`bucket`).
- **Live sync's endpoint** is the repository **variable** `IOT_ENDPOINT`
  (public: the account's `aws iot describe-endpoint --endpoint-type
  iot:Data-ATS`), which the Release workflow's `streamer` job builds in.
  The auth API attaches the live-sync IoT policy to the identity at the
  stream credentials too (`POST /api/auth/stream/credentials`), as at
  the app's.
- A profile's Cognito identity is made by the auth API for the profile
  (its developer identifier), whoever asks first; the streamer's Google
  tokens never reach Cognito.

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
  - **rclone:** secrets only in the environment, nothing turning its
    verification off, and put, move and delete against `rclone serve s3`;
    against a fake S3 (with rclone 1.60.1 and 1.69.3), an upload whose PUT
    answers another MD5 and a move whose copy does fail (`ErrNotVerified`)
    and leave no copy, no HEAD after a PUT, and an object there already
    whole not uploaded again;
  - **stream:** an empty chunk deleted; a subject stored as a phone would,
    in order, with sealed media that opens; resuming after a failure at
    each step without uploading twice; a failed move uploading the sealed
    copy; an upload at each step that fails verification keeping what it
    was for and deleting what's verified already, here and in the cloud's
    mode; a stop after the last upload deleting the chunk at the next try
    without uploading again; a search failing 3 times given up, but not a
    detector that's down; a broken chunk deleted, a cancelled probe not;
    the spool cap; the settings' key;
  - **cameras** (`main_cameras_test.go`): a Blink and a GoPro clip through
    its camera's pipeline, its first upload failing verification, stored
    once verified and then deleted from the device;
  - **live sync:** the presigned URL equal to the app's test vector;
    the WebSocket (masking both ways, 16- and 64-bit lengths, fragments
    with a ping between them answered, empty messages, a close; text,
    masked-from-server, reserved-bit, unknown-opcode, long or fragmented
    control, oversized and interleaved frames refused; a 403 handshake
    quoting neither URL nor body; an untrusted certificate refused; a hung
    server timing out; a 64 KB handshake refused); MQTT (remaining lengths
    from 1 to 4 bytes and a fifth refused, the packets' bytes, PUBLISH
    parsing with QoS 2, DUP, bad, wildcard, NUL and empty topics, and
    packet ID 0 refused, CONNACK and SUBACK, a refused connection, a
    connect timing out, malformed and oversized packets and a vanished
    server dropping the connection, keep-alive pings and a silent broker
    dropped, a full buffer dropping); pings parsed as the app's (and every
    malformed case refused, `sync` ignored); the event message's shape;
    and **end to end**, against an in-process TLS WebSocket server with a
    fake broker: a presigned URL with the session token, the client ID and
    clean session, the `requests` subscription, an event published on
    `events`, a ping answered on `acks` with its nonce, a second one within
    5 s, a `sync` and a malformed one not answered, its own and a 3-min-old
    ping not answered, one dated in the future answered, a reconnection
    with a new URL after the server drops it, a renewal before the
    credentials expire (the old connection disconnected), a back-off with
    fresh credentials through three 403s, a refused CONNACK and failing
    credentials logged, a refused subscription still publishing, a queue
    that never blocks and drops past 100, and no secret in any log line;
  - **stream:** an event published once it's in the bucket, with the very
    JSON uploaded, its key and MD5; not when its upload failed;
  - **state:** the lock against a second streamer;
  - **auth API:** `ProfileTest` (the bucket in the answer).
- **End to end** (`main_e2e_test.go`): a video (10 s of nothing, 10 s of a
  person) as the camera, through the real recorder, ffmpeg, detector and
  rclone into `rclone serve s3`, with Google and the auth API faked. The
  empty chunks were deleted. The ones with the person became events
  (`human` 0.99–1.00, with `dog` and `horse` from the photo), their
  recording and thumbnail opened with the device's key, ingest was empty
  after, and the settings carried the key. Passed on macOS (OpenCV 4.10).
  In the cloud's mode, with rclone 1.60.1 as the streamer's (Debian's)
  against 1.69.3's `serve s3`, each chunk was uploaded, verified and
  deleted from the device.
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
- **On a real Raspberry Pi Zero W** (2026-10-11): ARMv6, one core, 512 MB,
  Raspbian 13 armhf, Camera Module v2 (imx219), reached over SSH. The
  end-to-end test was cross-compiled with GOARM=6, ran on its camera, and
  uploaded to a local S3 there:
  - **Detection:** `auto` chose the cloud, as the Zero has 427 MB.
  - **Recording:** the camera module through `rpicam-vid` with the
    hardware encoder (`bcm2835-codec-encode`). The recorder takes about
    46 % of the CPU.
  - **Motion filter:** with the camera on a dark, still scene, every chunk
    scored 0.0 % and was deleted without an upload. The motion test passes
    on the Zero's own ffmpeg: a still picture has none, a moving pattern
    does.
  - **Upload, worst case** (filter off): with 30 s chunks the Zero kept up
    for 4 minutes, sealing and uploading each chunk and its job within its
    30 s. With 10 s chunks it can't. Its costs per chunk: sealing in Go at
    2.55 MB/s (1.2 s for 10 s of video), about 2.4 s per rclone call, and
    about 4 s for an ffprobe, which is why lengths now come from ffmpeg's
    segment list.
  - **Cloud detector, on those real chunks:** the function ran in AWS's
    Lambda Python 3.13 arm64 image (the runtime emulator) against a local
    S3 holding them. It opened each with the key the Zero published in its
    settings and searched it in about 0.4 s. It found no one in the dark
    and deleted them, leaving only the chunk stopped mid-upload.
  - **Timestamps:** the Zero's frame rate at 720p (about 23 fps) is why the
    camera now sends MPEG-TS (above). Its keyframes come every 1.1 s
    (`--intra` through libav works).
  - **The service's sandbox:** a unit with exactly its hardening, as its
    user, recorded with the camera module and the hardware encoder.
  - **The package:** the armhf `.deb` installed without OpenCV and was
    enabled for every boot.
- **The cloud detector:** `pytest` (34 tests).
  - **Seal:** the Python seal reproduces the Go fixture byte for byte and
    opens it.
  - **Handler, with a fake S3:** every outcome; a job twice done once; a
    missing key retried; jobs that don't match their key refused; writes
    only in the job's folder; the Go streamer's job fixture accepted.
  - **Labels:** the same as the Pi's.
  - **Untrusted input:** not an MP4, too big a picture, past the deadline,
    a job too big, times out of range, unwritable text, and settings that
    don't read are each refused or retried, and the work folder is
    emptied.
  - **Real detection:** a person found 1.5 s into a video.
  - **Built package:** in the Lambda arm64 image, with sealed jobs in a
    local S3, the person's chunk was stored (`human` 0.994) and its
    recording opened identical, and the empty one was deleted.
- **On a real Raspberry Pi 4** (2026-10-18): 8 GB, Debian 13 arm64, a
  USB Logitech C920, release 0.7.202610181624-GA, installed headless with
  the app's stream-key command (the arm64 `.deb`, with OpenCV):
  - **Recording:** `auto` chose the USB camera (`v4l2`, `/dev/video0`)
    with the hardware encoder (`h264_v4l2m2m`), 1280x720 at 15 fps.
  - **Detection:** on the device (7819 MB of memory). A chunk with a
    person (`human` 0.62) was stored as an event in the real bucket and
    deleted from the Pi; still chunks were deleted without an upload.
  - **Boot:** after a reboot the service started by itself (it waits for
    the network to set the clock) and ran with no restarts; the chunk the
    reboot cut off was found broken and deleted.
- **Not yet:** a Pi 5, a camera module on a Pi 4 or 5, the deployed cloud
  detector (a Pi that detects in the cloud), and a real Google
  sign-in.

## Known limitations

- **One streamer per profile streams** at a time; see [Streamer
  leadership](streamer-leader.md#known-limitations) for its own.
- **Live sync isn't verified against AWS IoT yet**, only against the
  fake broker (as the app's own tests); the Release builds carry the
  endpoint once the repository variable `IOT_ENDPOINT` is set.
- **Events the cloud detector stores** (a Pi under 2 GB, or
  `detection cloud`) aren't published over live sync: the cloud detector
  (`presence_ingest`) stores them, and they reach the devices from the
  bucket (15 s), as before.
- **Its Blink, GoPro and Reolink cameras don't answer pings**: only the
  streamer's own device shows live; the cameras show from their events.
- **No live sync while it waits** for the lead: a standby streamer has no
  credentials, so it doesn't show live.
- **Unattended sign-in lasts as long as Google's refresh token.** An OAuth
  app in Google's "Testing" status has its refresh tokens expire after 7
  days: publish it. A revoked or expired one stops the streamer (exit 2)
  until `setup` runs again.
- **A chunk is the clip:** a subject at the very end of one chunk and the
  start of the next makes two events.
- **No audio.**
- **A Pi Zero needs chunks of 30 s or more** (the default): it can't seal
  and upload 10 s chunks as fast as it records them. Under 2 GB of memory
  it doesn't search on the device at all (cloud detection).
- **Motion is scored a second apart**, between keyframes. Something that
  moves in and out between two keyframes isn't seen.
- **Cloud detection costs a Lambda run per chunk with motion** (about
  half a second at 2 GB), and its events reach the app a little later than
  a device-searched one's.
- **A flood of jobs can take the account's Lambdas.** The account's quota
  is 10 concurrent executions, all shared: a premium user uploading many
  jobs could throttle the auth API for everyone while they run. Each job
  is bounded (above), but no cap can be reserved until the quota is
  raised (Service Quotas, "Concurrent executions"). Then set
  `INGEST_CONCURRENCY` to a few.
- **The cloud detector can read every profile's keys.** Its role reads
  every device's settings, and it decodes a user's bytes. MP4 only and
  local files only narrow that. Credentials scoped to the job's folder (an
  assumed role with a session policy) would close it, but need a new role,
  which the deploy roles can't make yet.
- **Until the permissions boundary allows `s3:DeleteObjectVersion`,
  ingest's deleted chunks still stay 30 days as old versions** (the bucket
  is versioned), paying their storage. The function's role has it, but the
  stage's boundary (`<prefix>-app-boundary`, from `github-deploy.yaml`,
  applied by hand) doesn't yet; while it's refused, the function deletes as
  before (a delete marker) and logs `version kept`. The streamer's own
  deletes and moves in ingest (detecting on the Pi) leave old versions too.
  A lifecycle rule can't be the backstop: its filters are key prefixes, and
  ingest's keys are `<identity>/ingest/…`.
- **The SD card is written continuously** (the spool). `--state-dir` (or
  `PRESENCE_STREAMER_STATE_DIR`) on another disk or a tmpfs spares it.
- **No subject recognition** (who it is): only object detection. The app's
  **Auto**, or the profile's [cloud recognition](cloud-recognition.md),
  names them.
- Chunks are stored whole (up to 30 s), not cut to the subject.
