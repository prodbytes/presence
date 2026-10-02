# Add a device

Open Presence on another device, from a QR code or a shared link, as a new
device of the same user
([lib/identity/](../presence_app/lib/identity): `join_link.dart`,
`add_device.dart`).

## Sharing (Settings)

- **The last thing in Settings**, under the health line: an **Add a
  device** button with a QR-code icon. It shows once the device ID is known.
- It opens a dialog with:
  - a **QR code** of the link, dark on white with a quiet zone;
  - "Scan with another device to open Presence there as <email>. It becomes
    a new device, with its own ID." (no "as …" in DEV);
  - the link itself, small and selectable;
  - **Copy link**, and **Share**: the system's share sheet (Android, iOS,
    and the Web Share API where the browser has it). Where there's no share
    sheet, Share copies the link instead. Both say "Link copied".

## The link

`<app>/?from=<device ID>&user=<user code>`, where `<app>` is the page's
own address on web (e.g. `https://presence.nu01.com/app/`), and the site's
`/app/` (`API_BASE_URL`, production by default) on Android and iOS.

- `from`: the device ID of the device that shared it.
- `user`: who was signed in there, as a **user code**: the first 16 hex
  digits of SHA-256(`presence-join:` + the Google account ID). The QR code
  doesn't carry the account ID or the email. Left out in DEV, where nobody
  signs in.
- It carries no token or secret. Joining is a sign-in on the new device:
  the link only says which account to sign in with.

## Opening it

The link is a plain `https` URL:

- **No app** (a laptop, or a phone without Presence): it opens the site,
  which is the app on web.
- **Android with the app:** an App Link (an intent filter for
  `https://presence.nu01.com/app…` and `https://rc.presence.nu01.com/app…`)
  hands it to the app (`app_links`). Android opens it there without asking
  only once the site has the app's `/.well-known/assetlinks.json` (see the
  limitations); until then, Android opens it in the browser, unless the
  user turns on the app's supported links in its Android settings.
- **iOS:** the site, in the browser (no Universal Links yet).

The app reads the link it's opened with (the page's address on web, the App
Link on Android), and any it's sent while running. Other links are ignored.

## Joining

The device that opens the link keeps (or, on first launch, makes) **its own
device ID** ([Devices, users and places](devices-users-places.md)). The
link's device ID is never used as this device's. Then, with a banner at the
top of the screen, over every tab, until it's done or dismissed (✕):

| Where it stands | What shows |
|---|---|
| The device ID is loading, or the launch sign-in check is running | nothing yet |
| This is the device that shared the link (`from` is this device's ID) | "This is the device that shared the link. Open it on another device to add that one." |
| Signed out (RBAC) | "To add this device, sign in with the Google account that shared the link." The app bar's sign-in button does the rest |
| Signed in as another account (the user code doesn't match) | "The link was shared by another Google account than <email>…", with **Sign out** |
| Signed in as the same account, or DEV, or a link without a user | joined: a message "This device is now one of <email>'s: <device ID>" (in DEV, "Presence is open on this device: <device ID>"), as the camera's message pill, or a snackbar on another tab; no banner |

- Once joined or dismissed, the link is done. On web, the page's query is
  dropped from the address (`history.replaceState`), so a reload doesn't
  handle it again.
- Joined, the device is like any other of the user's: their roles decide
  what shows ([Sign-in](sign-in.md)), and [cloud sync](cloud-sync.md) keeps
  its settings in the user's folder under its own device ID.
- An account without `presence_user` that signs in on the new device still
  gets only sign-up; the link doesn't grant access.

## Verified

- `add_device_test.dart`:
  - the link has the device ID and the user code, not the account ID; it
    reads back; links without `from` aren't join links;
  - every row of the table above, from `JoinStatus.of`;
  - Settings ends with Add a device, below the device ID, and its QR code,
    Share and Copy link; the link is this device's and the user's; in DEV
    it has no user;
  - opened signed out: the sign-in banner; signing in as the same user
    joins, with the message, and the device keeps its own ID;
  - signed in as another user: the banner, Sign out, then the sign-in
    banner, dismissed with ✕;
  - opening the device's own link says to use another device.
- The web release and an Android debug APK build. Not yet run on a phone:
  scanning, the share sheet and the App Link.

## Known limitations

- **No `assetlinks.json` yet:** it needs the release signing key's SHA-256
  (the app is signed with a debug key, recorded in the private repo), so
  Android doesn't open the links in the app by itself.
- **iOS** opens the site: Universal Links need an Apple Team ID (none yet),
  the Associated Domains entitlement and an `apple-app-site-association`
  file.
- A link shared from a local dev server (`localhost`) only works on the
  same machine.
- Opened on a device that already had Presence, the device keeps its ID and
  history: "a new device" means a device other than the one that shared it.
- The user code identifies the account across links: anyone with the QR
  code can tell two links come from the same account (not which one).
