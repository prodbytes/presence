# USB cameras

Cameras plugged into a Linux [streamer](streamer.md) of the profile (a
Raspberry Pi) by **USB** become Presence devices, with **no network and no
address**: the streamer detects them, the app adds them by name, and the
streamer fetches each one's new videos as if it had recorded them. Each
video goes through the streamer's chunk pipeline (sealed, uploaded,
searched for people and animals), as a device of its own, and **every
video is kept** as an event, tagged with whoever's in it (`KeepAll`: they're
taken on purpose), then recognized by the app like the streamer's own
clips. Premium only (the streamer is).

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
  why they can't be ("Can't fetch: the camera is busy: …"), or "Not
  plugged in: its new videos are fetched once it's back"; and a **Remove**
  button (`{remove: <device ID>, requestedAt}`).
- **Plugged into it, to add:** the cameras the streamer detects and that
  aren't added, each as "GoPro HERO6 Black · C3221324700631" with a
  **name** field (its model at first) and **Add**. Add sends `{add: {name,
  serial}, requestedAt}` to `devices/<streamer>/usbcam.json`, **sealed
  with the streamer's media key** (`CloudSync.putDeviceFile`); "Sent to
  <streamer>; it looks every 30 s…" till it answers, the buttons waiting
  meanwhile. With none: "No other camera plugged into it. Plug one in and
  turn it on: it shows here within a minute."
- **The streamer's answer**, `devices/<streamer>/usbcam-status.json`
  (sealed with its key; read every 10 s while the section shows):
  `{state: off | ok | error, error, detected: [{model, serial, port}],
  cameras: [{name, model, serial, deviceId, plugged, lastFetch, error}],
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
  in `usbcam-state.json` (mode 600, the state folder) with the model. The
  cameras' IDs go with the streamer's credentials requests, as Blink's,
  GoPro's and Reolink's do, so they join the profile's devices at once
  (`Session.Register`). A camera can be added while unplugged (its serial
  was detected before). The request is deleted from the cloud once
  handled.
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
  - **Download:** `gphoto2 --port <port> --get-file <path> --filename
    <…>.part --force-overwrite`, which streams it to disk; checked
    against the size the listing said (in KB), then named like the Pi's
    chunks with its UTC start (`rec-usbcam-20261014T100000.mp4`) in
    `usbcam-incoming/<device>/`, and moved into **its camera's spool**
    (`spool/usbcam/<device>/`), where a pipeline of its own takes it: the
    Pi's own settings, the camera's device ID and name (the events'
    `cameraName`), `cameraId: usbcam`, `os: USB camera`, every video kept,
    and `storedAt`. Where it got to is saved after each video.
  - **Big files:** a video bigger than half the spool (`--spool-max-mb`)
    is skipped and logged. A download cut off (gphoto2 failing, or a size
    that doesn't match) is deleted and tried again at the next fetch; one
    left in `usbcam-incoming/` by a stop is handed over at the next fetch.
  - **Nothing is deleted on the camera.**
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
  detected again only when the kernel's list changes; added (registered,
  the request deleted), its videos since the backfill fetched (`.MP4`,
  `.MOV`; not `.LRV`, `.THM`, `.JPG`, nor one too big), nothing twice,
  also after a restart, a new one fetched, those gone forgotten, nothing
  left in incoming; removed; the same request not handled twice;
  unplugged (`plugged: false`, no error, not listed), then replugged on
  another port and fetched at once by serial; busy (the error said), a
  download cut off deleted and fetched again; a serial from `--summary`;
  gphoto2 missing; `--list-files` parsing. `main_cameras_test.go`: a USB
  camera's video through its pipeline.
- The app (`usb_camera_settings_test.dart`): no streamer; nothing plugged
  in; a detected camera added with its serial and the name typed (its
  model at first), then listed (no longer offered) and removed; unplugged,
  a camera's error and the streamer's error; a send that fails; the
  streamer picked kept for USB cameras only; 320 dp.

## Known limitations

- **Not tried on the Pi yet** with the GoPro HERO6 (whose `gphoto2
  --auto-detect` listing and gvfs mount were seen there); the udev rule's
  effect on gvfs is from gvfs's sources.
- The rule hides **every** still-image camera from the desktop, not only
  the ones added (the package can't know which; see above to undo it).
- The camera must be on and plugged in; a GoPro powers off by itself
  after a while (its Auto Power Off setting) and isn't woken.
- A video still being recorded isn't listed till it's done; a long
  recording's chapters come as separate videos.
- Up to 16 cameras per streamer, Blink's, GoPro's, Reolink's and USB ones
  together (the auth API's limit). Only the leading streamer fetches.
