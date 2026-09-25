# Presence — software specification

The current specification of the product. Update it whenever a request changes
what the software does or how it is built. [requests.md](requests.md) holds the
history of requests that shaped it.

## Product

Presence is a surveillance app. It shows live camera feeds and a stream of
events detected from them.

## User interface

The app is a Flutter app ([presence_app/](../presence_app)). The main screen
has two panels:

| Panel | Position | Contents |
|-------|----------|----------|
| Cameras | Left, takes all remaining width | Titled with the app name. Live feeds from every camera on the device, in a grid. |
| Events | Right, always 360 px wide | Timeline of events, newest first. |

- The layout is the same at every window size: the Events panel never
  resizes, and the Cameras panel fills the rest. There is no stacked
  narrow-screen layout, so on phone-sized screens the Cameras panel gets very
  little width.
- Header buttons are tonal filled icon buttons, 8 px apart.

### Theme

The colors follow **Gruvbox dark, soft contrast**, defined in
[lib/theme.dart](../presence_app/lib/theme.dart):

| Role | Gruvbox color | Hex |
|------|---------------|-----|
| Page background | bg0_s | `#32302f` |
| Panels | bg1 | `#3c3836` |
| Event cards, header buttons, dividers | bg2 | `#504945` |
| Camera tile background | bg0_h | `#1d2021` |
| Text | fg | `#ebdbb2` |
| Secondary text | fg4 | `#a89984` |
| Primary accent (app title, event icons, spinners) | yellow | `#fabd2f` |
| Secondary accent | aqua | `#8ec07c` |
| Errors | red | `#fb4934` |

The web manifest's `theme_color` and `background_color` are also `#32302f`.
- The Flutter demo UI was removed entirely.

### Cameras panel

- The panel title is the app name, **Presence**, in the accent color. It links
  to https://presence.nu01.com and opens in a new tab. On web it's a real link,
  so middle-click and "open in new tab" work.
- The header has a **Clip** button (camera icon) at its top right. It's a
  placeholder for now: it shows a tooltip but takes no action.
- On load, the app opens every camera available to the device and shows each
  one as a live tile. On web, the browser asks for camera permission first.
- The grid has ceil(√n) columns, and the tiles fill the panel.
- Each tile shows the camera's label at the bottom left, or "Camera" if the
  browser hides device labels.
- Feeds are video only; audio is not captured. Resolution preset: medium.
- States:
  - **Loading:** a spinner while cameras are discovered or opened.
  - **No cameras:** "No camera feeds", with a Retry button.
  - **Access error:** for example, permission denied. Shows the error and a
    Retry button.
  - **Per-tile error:** if one camera fails to open (for example, it's in use),
    only that tile shows the error.

### Events panel

- The header has two icon buttons at its top right, in this order:
  - **Settings** (gear icon)
  - **Login** (person icon)
- Both buttons are placeholders for now: they show tooltips but take no
  action.
- Events appear in a vertically scrolling timeline, newest at the top. Each
  entry is just a card, with no dot or rail beside it, and cards are 8 px
  apart.
- Each event card shows an icon, a title, an optional detail line and the time
  (HH:mm:ss).
- When a new event arrives, the timeline scrolls back to the top to show it.
- On launch, the app pushes an **Application started** event.
- With no events, the panel shows a "No events" empty state.
- The event log belongs to the main screen, not the panel, so other parts of
  the app can push events to it.

## Platforms

- Web is the primary development target. `devbox services up` (or
  `devbox run web` on its own) serves it at http://localhost:8080. The port can
  be changed with `FLUTTER_WEB_PORT`.
- Links open through the `url_launcher` package.
- Camera access uses the official `camera` plugin, which supports web, Android
  and iOS. macOS and Linux desktop have no camera implementation.
- The Android, iOS, Linux and macOS scaffolding from `flutter create` is kept.
- iOS: `Info.plist` declares `NSCameraUsageDescription`, which the camera
  plugin needs. There's no microphone key because feeds are video only.
  Running on a physical iPhone requires full Xcode, a connected or paired
  iPhone with Developer Mode on, and a signing team. The bundle ID is still
  the placeholder `com.example.presenceApp`.

## Development environment

- [devbox.json](../devbox.json) manages the toolchain: GraalVM CE (musl),
  Python, Node.js, Go, PostgreSQL and Flutter.
- The dev container ([.devcontainer/](../.devcontainer)) installs devbox and
  includes the Dart and Flutter VS Code extensions. It forwards port 8080 for
  Flutter web.
- Flutter web runs on the `web-server` device, so the container doesn't need
  Chrome.
- `devbox services up` ([process-compose.yaml](../process-compose.yaml)) starts
  PostgreSQL, the Flutter web server (`2-flutter-web`, via
  [scripts/flutter-web.sh](../scripts/flutter-web.sh), with an HTTP readiness
  probe) and the health monitor, which logs the status of both the database
  and the web app.
- The app requires Dart SDK `^3.13.0`, which covers the Nix Flutter 3.47.0
  (Dart 3.13.0).

## Workflow

- Every change goes on its own branch, with its own pull request. Nothing is
  pushed directly to `main`. See [CLAUDE.md](../CLAUDE.md).
- Every request updates this spec and the [request log](requests.md) in the
  same PR.

## Known limitations

- `graalvmPackages.graalvm-ce-musl` is Linux-only, so `devbox install` fails on
  macOS hosts. Use the dev container, or a locally installed Flutter SDK.
- The Nix Flutter package has no `x86_64-darwin` (Intel Mac) build.
