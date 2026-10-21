# USB cameras

Cameras plugged into a Linux [streamer](streamer.md) of the profile (a
Raspberry Pi) by **USB** become Presence devices, with **no network and no
address**: the streamer detects them, the app adds them by name, and the
streamer fetches each one's new videos as if it had recorded them. Each
video is cut into chunks, as the streamer's own recordings are, that go
through its chunk pipeline (sealed, uploaded, searched for people and
animals), as a device of its own, then recognized by the app like the
streamer's own clips. Premium only (the streamer is).

A camera is **unattended** by default, for one left recording all along:
only the chunks **with movement** are kept (the streamer's motion filter;
those without are deleted unsent), and each video is **deleted from the
camera** once it's downloaded whole, so its card doesn't fill up. Turned
off, **every chunk is kept** as an event and nothing on the camera is
deleted (videos taken on purpose). Either way, a chunk kept is an event
tagged with whoever's in it, someone there or not (`KeepAll`).

Which cameras: **still-image cameras** (USB interface class 6), which
speak PTP, or MTP over it: a **GoPro HERO5 to HERO8** (which have no Open
GoPro HTTP API, so not [GoPro cameras](gopro.md)), most digital cameras
(Canon, Nikon, Sony, Fujifilm…), and an action camera that shows up as a
camera or a media device. The streamer talks to them with libgphoto2's
`gphoto2` command. A camera is known by its **USB serial number**, the same
on any port and after a replug; never by an address.

Not these: a USB webcam (that's the streamer's own camera, `--source
v4l2`), a camera that only shows up as a USB drive (mass storage), a phone
in MTP mode (its interface isn't a still-image one), a GoPro HERO9 or newer
by USB (that's networking: see [GoPro cameras](gopro.md)).

## In the app

Settings' **USB cameras** section, after [Reolink cameras](reolink.md)
(`UsbCameraSettings`,
[usb_camera_settings.dart](../presence_app/lib/usb_camera_settings.dart)),
for a premium profile with cloud sync, not in DEV:

- **Without a Linux streamer** in the profile, it says to set one up first
  (the cameras are plugged into it).
- **The streamer** they're plugged into: as [Blink's](blink.md#in-the-app),
  a dropdown whose default is **Leader (<device>)**, the profile's
  [leading streamer](streamer-leader.md), then the profile's Linux
  devices. Picking one keeps it **for USB cameras only**
  (`IntegrationsConfig`, `usbcam`). Only the leading streamer fetches.
- **Its USB cameras**, from its status: each camera's name and device ID,
  its model and serial number, then when its videos were last fetched,
  why they can't be ("Can't fetch: the camera is busy: …", "Can't fetch:
  waiting for room on the streamer: …", "Can't fetch: couldn't delete …
  from the camera: …"), or "Not plugged in: its new videos are fetched
  once it's back"; its **Unattended: keep only the parts with movement
  and delete videos from the camera once fetched** switch (from the
  status's `unattended`; none when the streamer doesn't say, an older
  one), which sends `{set: {deviceId, unattended}, requestedAt}` and shows
  the value sent till the streamer answers; and a **Remove** button
  (`{remove: <device ID>, requestedAt}`).
- **Plugged into it, to add:** the cameras the streamer detects and that
  aren't added, each as "GoPro HERO6 Black · C3221324700631" with a
  **name** field (its model at first), the **Unattended** switch (on at
  first) and **Add**. Add sends `{add: {name, serial, unattended},
  requestedAt}` to `devices/<streamer>/usbcam.json`, **sealed
  with the streamer's media key** (`CloudSync.putDeviceFile`); "Sent to
  <streamer>; it looks every 30 s…" till it answers, the buttons waiting
  meanwhile. With none: "No other camera plugged into it. Plug one in and
  turn it on: it shows here within a minute."
- **The streamer's answer**, `devices/<streamer>/usbcam-status.json`
  (sealed with its key; read every 10 s while the section shows):
  `{state: off | ok | error, error, detected: [{model, serial, port}],
  cameras: [{name, model, serial, deviceId, unattended, plugged, lastFetch,
  error}],
  requestedAt, updatedAt}`. A streamer's error ("gphoto2 isn't installed")
  shows in red as "USB cameras: …".
- A send that can't go (the streamer's key not here yet, cloud sync off)
  says so. The section fits 320 dp.
- USB cameras show in the device list with a camera icon
  (`DeviceOs.iconOf('USB camera')`).

## On the streamer

The `usbcam` package
([usbcam.go](../presence_streamer/internal/usbcam/usbcam.go)), started by
`main_usbcams.go`, while the streamer leads; on unless `--usbcam off`
(`PRESENCE_STREAMER_USBCAM`). `--gphoto2` names the command (`gphoto2`),
`--usbcam-every` how often videos are fetched (2m).

- **Every 30 s** it looks for the app's request, and for the cameras
  plugged in. That look is cheap: it reads the kernel's USB list
  (`/sys/bus/usb/devices`) for devices with a still-image interface
  (`bInterfaceClass` 06). Only when that list changes (a camera plugged,
  unplugged, replugged) does it run `gphoto2 --auto-detect`; nothing at
  all runs while none is plugged in. Each camera's serial number is the
  kernel's (`serial`, matched by bus and device number), else the one
  `gphoto2 --port usb:BUS,DEV --summary` says ("Serial Number:"); one
  without any can't be added (logged). gphoto2 runs with `LC_ALL=C`, as
  its output is read.
- **The status** is put when something changed (a camera plugged in or
  out, a request handled, a fetch), and once at the start.
- **Add:** by serial: a new device ID (`ids.NewDevice`), or the old one for
  a serial already added (its name updated, what was fetched kept), kept
  in `usbcam-state.json` (mode 600, the state folder) with the model and
  its mode: `unattended` as sent, **on** when not said (a new camera), or
  as it was (one added again). Cameras added before the mode existed are
  **unattended too**, as none was stored off. The
  cameras' IDs go with the streamer's credentials requests, as Blink's,
  GoPro's and Reolink's do, so they join the profile's devices at once
  (`Session.Register`). A camera can be added while unplugged (its serial
  was detected before). The request is deleted from the cloud once
  handled.
- **Set:** `{set: {deviceId, unattended}}` changes an added camera's mode,
  kept and given to its pipeline at once (its next chunk follows it).
- **Remove:** the camera is forgotten and its pipeline stops; its device
  and events stay. Nothing on the camera changes.
- **Fetching, every 2 minutes**, and at once when an added camera is
  plugged in: for each added camera that's plugged in, `gphoto2 --port
  <port> --list-files`, then each video not fetched yet, oldest first:
  - **Videos only:** `.MP4` and `.MOV`; not photos, nor a GoPro's
    low-resolution copies and thumbnails (`.LRV`, `.THM`).
  - **Not twice:** each video fetched is kept by its path on the camera
    (`/store_00010001/DCIM/100GOPRO/GOPR0002.MP4`) with its size and time;
    the same path with another size or time (a file written over) is
    fetched again. Those no longer on the camera are forgotten.
  - **Backfill:** a new camera's first fetch goes back **24 hours**, by
    the file's time (libgphoto2 reads the camera's clock as the
    streamer's local time, so the two should share a time zone). A file
    without a time is taken as old on the camera's first listing, and
    fetched after.
  - **Not while it's written:** a video is fetched only once its size and
    time are the same in two listings: the last fetch's, or, for one new
    since, a second listing 5 s later. One still growing (the video being
    recorded, if the camera lists it) waits for the next fetch ("still
    being written"), and is neither downloaded nor deleted till then.
  - **Room:** a video is downloaded only when **twice its size** (it, then
    its chunks while it's split) leaves 512 MB free on the state folder's
    disk; otherwise the camera's error says "waiting for room on the
    streamer: GOPR0002.MP4 needs 8703 MB, 3000 MB free", and it's tried
    at the next fetch, as chunks handed over free the room. There's no
    size limit otherwise: a GoPro's 4 GB chapters are fetched.
  - **Download:** `gphoto2 --port <port> --get-file <path> --filename
    <…>.part --force-overwrite`, which streams it to disk; checked
    against the size the listing said (in KB), then named with its UTC
    start, `usbcam-incoming/<device>/video-20261014T100000.mp4` (a second
    later when another video has that start). Where it got to is saved
    after each video. A download cut off (gphoto2 failing, or a size
    that doesn't match) is deleted and tried again at the next fetch.
  - **Deleted from the camera (unattended):** once a video is downloaded
    and its size checked, it's on the streamer's disk, and it's deleted
    from the camera: `gphoto2 --port <port> --delete-file <path>` (a path,
    which gphoto2 takes as a file when it has a dot; not a file number,
    which a delete shifts), its own sidecars first: the `.LRV` and `.THM`
    of the same name beside it (`GOPR0002.LRV`, `GOPR0002.THM`), or the
    `GL` low-resolution copy of a `GH`/`GX` video (`GL010002.LRV` for
    `GH010002.MP4`). Nothing else is deleted: not photos, not another
    video's sidecars, not a video cut off, still growing, or listed
    without a size (which can't be checked), nor one never fetched (from
    before the backfill). The videos downloaded whole and still on the
    camera are kept (`got`, in its state): a delete that fails is said in
    the camera's error ("couldn't delete … from the camera: …") and tried
    again at each fetch, also after a restart, without fetching the video
    again. A camera turned unattended later has the videos it fetched
    whole since deleted at its next fetch.
  - **Split into chunks:** right after its download, each video is cut by
    ffmpeg into chunks of `--chunk` (30 s) at keyframes, copied, not
    encoded again (`-c copy`, the segment muxer, as the recorder's), with
    its first video and audio streams only, no timecode track (a GoPro's
    timecode and telemetry streams don't fit an MP4 chunk). Each is named
    by its UTC start, the video's plus its offset from ffmpeg's segment
    list: `rec-usbcam-20261014T100030.mp4`. They're made in
    `split-<start>/`, which becomes `chunks-<start>/` once they're all
    there; then the whole video is deleted. A video ffmpeg can't cut is
    handed over whole (the pipeline deletes one it can't read).
  - **Handed over** oldest first into **its camera's spool**
    (`spool/usbcam/<device>/`), where a pipeline of its own takes them:
    the Pi's own settings, the camera's device ID and name (the events'
    `cameraName`), `cameraId: usbcam`, `os: USB camera`, every chunk kept
    (`KeepAll`), `storedAt`, and, unattended, the streamer's **motion
    filter** (`--motion-min`, 5 %: a chunk at or under it is deleted
    unsent, "no motion"). A chunk goes in only while the camera's spool
    holds less than **half of `--spool-max-mb`** (one at least when it's
    empty; the pipeline seals a copy beside each), so the spool's limit,
    which drops the oldest chunks unsent, never drops one, nor touches a
    video being split (outside the spool); the rest wait in incoming, and
    are handed over every 30 s as room frees.
  - **A stop anywhere carries on:** a `.part` or a `split-` folder is
    deleted (fetched, or split, again); a video whose `chunks-` folder is
    there is deleted; the chunks waiting are handed over.
- **A camera another program holds** (gphoto2: "Could not claim the USB
  device"): its error says "the camera is busy: another program (the
  desktop's file manager) has it open", and it's tried again at the next
  fetch. **Unplugged:** not an error; `plugged: false`.
- **gphoto2 missing:** the status says "gphoto2 isn't installed (sudo apt
  install gphoto2)" (the `.deb` depends on it).

## The desktop and permissions

On Raspberry Pi OS with the desktop, gvfs mounts a camera as it's plugged
in (`gvfsd-mtp`, or `gvfsd-gphoto2`, as the desktop user), which holds its
USB interface: gphoto2 then can't claim it. The `.deb` ships
`/lib/udev/rules.d/85-presence-streamer-usbcam.rules`, for USB devices
with a still-image interface only (`ID_USB_INTERFACES` `*:06????:*`):

- `GROUP="plugdev", MODE="0660"`: the `presence-streamer` user (in
  `plugdev`, added by postinst) may open them (`/dev/bus/usb/BBB/DDD`).
  The desktop user keeps its own access (logind's `uaccess` ACL).
- It unsets `ID_GPHOTO2` and `ID_MTP_DEVICE`, which libgphoto2's and
  libmtp's rules (60-, 69-) set: gvfs's gphoto2 and MTP volume monitors
  take only devices with one of them (`g_udev_device_has_property`, on
  `add` and at start), so the desktop no longer mounts them.
- postinst reloads the rules and re-triggers the cameras plugged in; one
  the desktop mounted already needs a **replug** (gvfs ignores `change`
  events). To give cameras back to the desktop:
  `sudo ln -s /dev/null /etc/udev/rules.d/85-presence-streamer-usbcam.rules`
  and replug.
- The service's sandbox lets it reach them: no `PrivateDevices=` or
  `DeviceAllow=`; `ProtectSystem=strict` leaves `/dev` alone; netlink is
  allowed (libusb); gphoto2's settings go to its home, the state folder.

## Tests

- `presence_streamer/internal/usbcam` (a fake `gphoto2` shell script and a
  fake `/sys/bus/usb/devices`): nothing plugged in runs no gphoto2 and puts
  one status; a GoPro HERO6 detected with its serial from the kernel,
  detected again only when the kernel's list changes; added attended
  (registered, the request deleted), its videos since the backfill fetched
  (`.MP4`, `.MOV`; not `.LRV`, `.THM`, `.JPG`), nothing twice, also after
  a restart, a new one fetched, those gone forgotten, nothing left in
  incoming, nothing deleted on the camera; removed; the same request not
  handled twice; unplugged (`plugged: false`, no error, not listed), then
  replugged on another port and fetched at once by serial; busy (the error
  said), a download cut off deleted and fetched again (and never deleted
  from the camera); a serial from `--summary`; gphoto2 missing;
  `--list-files` parsing. Unattended (the default): each video deleted
  from the camera after its download, its `.LRV`/`.THM` (`GL…LRV` for a
  `GH`) first, not photos, nor a video from before the backfill or its
  sidecar; a delete that fails said, and done at the next fetch after a
  restart, without fetching again; a growing video neither fetched nor
  deleted till its size holds; a 4 MB video waiting for room, then
  fetched; the mode added off, set on (the video fetched before deleted
  then), off, and kept on a re-add; a video split into chunks named by
  their start, handed over while the spool has room, the rest after;
  incoming after a stop (a split cut off done again, a video split
  already deleted); sidecars; `SplitVideo` with real ffmpeg (skipped
  without it): a 7 s video with sound and a timecode track cut every 2 s
  into 4 chunks named +0, +2, +4, +6 s, video and audio only; a broken one
  fails. `main_cameras_test.go`: a USB camera's video through its
  pipeline; unattended, a still chunk deleted unsent and a moving one
  kept with no one in it, and, turned off, a still one kept.
- The app (`usb_camera_settings_test.dart`): no streamer; nothing plugged
  in; a detected camera added with its serial and the name typed (its
  model at first), unattended, then listed (no longer offered) and
  removed; the add form's Unattended switch on at first, turned off and
  sent; a camera's switch showing its mode, none for an older streamer's,
  sending `set` and showing the value sent while waiting; unplugged,
  a camera's error and the streamer's error; a send that fails; the
  streamer picked kept for USB cameras only; 320 dp.

## Known limitations

- **A GoPro HERO5–8 drops USB while it records** (seen on a HERO6 Black,
  2026-10-19: a USB disconnect as recording starts, the camera gone from
  `lsusb`, and gphoto2's "Unspecified error" on the fetch that was under
  way): its videos can only be fetched while it isn't recording, so it
  can't be left recording and fetched over USB at the same time. Stop
  the recording (the camera then comes back on USB and is fetched, and
  in unattended mode emptied); continuous recording needs the camera
  controlled over its Wi-Fi, a HERO9 or newer, or a webcam on the
  streamer.

- **Not tried on the Pi yet** with the GoPro HERO6 (whose `gphoto2
  --auto-detect` listing and gvfs mount were seen there); the udev rule's
  effect on gvfs is from gvfs's sources.
- The rule hides **every** still-image camera from the desktop, not only
  the ones added (the package can't know which; see above to undo it).
- The camera must be on and plugged in; a GoPro powers off by itself
  after a while (its Auto Power Off setting) and isn't woken.
- A video still being recorded isn't listed till it's done (MTP); if a
  camera lists it, it waits till its size holds. A long recording's
  chapters come as separate videos, split each into chunks.
- A video's start is its file time as the camera lists it (taken as the
  recording's start; a camera giving its end shifts the chunks' times by
  the video's length). Not tried with the HERO6's 4 GB chapters yet.
- **Unattended, the card can still fill** when the streamer is slower than
  the camera (each chunk's motion is decoded from its keyframes: a 4K or
  HEVC video costs more on a Pi), offline for long (the chunks wait on
  its disk, then fetching waits for room), or the camera off the streamer.
  Videos from before the camera was added (the backfill) and photos stay
  on the camera.
- Up to 16 cameras per streamer, Blink's, GoPro's, Reolink's and USB ones
  together (the auth API's limit). Only the leading streamer fetches.
