# presence-streamer

Makes a Raspberry Pi with a camera a Presence camera for a **Premium**
profile, with no screen. It records continuously and uploads every chunk.
It keeps the chunks with a person or an animal in them as events in the
profile, as a phone keeps its motion clips. The full specification is in
[specs/streamer.md](../specs/streamer.md).

Works on Raspberry Pi OS **32-bit (armhf)** and **64-bit (arm64)**,
Bookworm or newer, on every Pi from the Zero to the 5.

## Install

On the Pi, from the release's `.deb` for its architecture (`dpkg
--print-architecture` says `armhf` or `arm64`):

```sh
sudo apt install ./presence-streamer_<version>_<arch>.deb
sudo presence-streamer setup
```

`setup` asks for the **profile ID** (the app shows it in the account
sheet), then for a **Google sign-in**. You enter a code at
google.com/device on your phone, with an account of that profile. It keeps
Google's refresh token and trades each Google ID token for a Presence
session token (`POST /api/auth/session`), which its auth API calls carry.
It checks the profile is Premium, then starts `presence-streamer.service`, which runs
at every boot. A free profile is refused: the streamer exits.

- Follow it: `journalctl -fu presence-streamer`
- Settings (camera, size, chunk length, location…): `/etc/default/presence-streamer`,
  then `sudo systemctl restart presence-streamer`
- `presence-streamer status`, `sudo presence-streamer sign-out`

Without the package, the release's tarball runs as is
(`./presence-streamer`, with `presence-detect.py` and `models/` beside it).
It needs `ffmpeg`, `rclone`, `python3-opencv` and, for the camera module,
`rpicam-apps`.

## What it does

1. **Records** the camera module (`rpicam-vid`) or a USB camera (ffmpeg
   v4l2) as H.264. It uses the Pi's hardware encoder on a Pi 4 and earlier,
   and libx264 on a Pi 5, which has none. Chunks are 30 s MP4s in
   `/var/lib/presence-streamer/spool/`.
2. **Uploads** each chunk, sealed with the device's key (AES-256-GCM, the
   app's format), to `<profile folder>/ingest/<device>/` with rclone.
3. **Searches** its keyframes, one a second, for people and animals with
   YOLOv4-tiny (COCO) in OpenCV.
4. **No one there:** the chunk is deleted, on the Pi and in ingest.
   **Someone there:** the chunk moves to `media/`, with a thumbnail, a clip
   record and a `clip_requested` event (trigger `motion`, its object
   tags). The app shows it like any motion clip.

## Develop

```sh
cd presence_streamer && go test ./...      # unit tests
bash scripts/streamer.sh                   # armhf + arm64 tarballs (and .debs with dpkg-deb)
go run . run --source test --api https://rc.presence.nu01.com   # the test pattern, no camera
```

`main_e2e_test.go` runs the whole pipeline against rclone's own S3 server
(see the test for its settings).

The model, YOLOv4-tiny from [darknet](https://github.com/AlexeyAB/darknet)
(YOLO license), is downloaded at build time and checked against its SHA-256.
