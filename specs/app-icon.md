# App icon

A camera lens in the Gruvbox palette: a yellow ring (`#fabd2f`) on the dark
background (`#32302f`), a dark iris with a blue glint, and a red recording
dot on the ring.

- **Masters:** SVGs in
  [presence_app/assets/icon/](../presence_app/assets/icon), rendered to
  1024×1024 PNGs with headless Chrome.
  - `icon.png` is the full, opaque icon, used for iOS, web and legacy
    Android.
  - `icon_foreground.png` is the art on transparency, used for Android's
    adaptive-icon foreground layer.
- **Generated** by `flutter_launcher_icons` (configured in `pubspec.yaml`;
  rerun with `dart run flutter_launcher_icons` after editing the masters):
  - **Android:** `mipmap-*/launcher_icon.png`, plus an adaptive icon
    (foreground inset 16% for the safe zone, background `#32302f`). The
    default Flutter `ic_launcher.png` icons were removed.
  - **iOS:** the whole `AppIcon.appiconset`, with alpha removed.
  - **Web:** `favicon.png`, `Icon-192/512` and maskable variants, plus the
    manifest colors.
- Verified on the S40: the adaptive icon shows in Recents, next to the app
  name "Presence".
- **The RC site's icons are different:** a huge dark **"RC"** on Gruvbox
  red (`#fb4934`), so an rc.presence.nu01.com tab or home-screen icon never
  passes for production's. Masters `icon_rc.svg` and
  `icon_rc_maskable.svg` (letters inside the safe zone) in
  [presence_app/assets/icon/](../presence_app/assets/icon), rendered to
  1024 px with headless Chrome and resized with `sips` into
  [presence_app/web_rc/](../presence_app/web_rc): `favicon.png` (64 px)
  and `icons/Icon-192/512` and their maskable variants.
  `scripts/deploy.sh` copies `web_rc/` over the web build only for
  `STAGE=rc` (see [Production deploy](deploy.md)); production and every
  other build keep the lens.

## Name

The app is called **Presence** wherever people see its name, never by its
Dart package name (`presence_app`):

- **Web:** the page title (the browser tab, and the link text when its URL
  is dragged or shared), `apple-mobile-web-app-title`, and the manifest's
  `name` and `short_name` (installed web app). The page and manifest
  description says what the app does.
- **Android:** the launcher label (`android:label`).
- **iOS:** `CFBundleDisplayName` and `CFBundleName`.
- **Linux:** the window and header bar titles. The binary (`presence_app`)
  and application ID keep the package name: the install script runs the
  bundle's `presence_app`.
- **In the app:** `MaterialApp.title` (`AppVersion.title`).
- **On the RC site** (rc.presence.nu01.com) the name is marked: the tab
  title, `index.html`'s `<title>` and the manifest's `name` are
  **"🧪 Presence RC"** (`short_name` "Presence RC"). The RC deploy builds
  with `PRESENCE_STAGE=rc` (compiled in, `AppVersion.stage`) and rewrites
  the built `index.html` and `manifest.json`, so the tab is marked even
  before the app starts. Production and other builds keep "Presence".
