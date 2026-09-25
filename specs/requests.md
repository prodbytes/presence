# Request log

Requests that shaped the specification, oldest first. Each entry summarizes
what was asked and what changed. See [README.md](README.md) for the current
spec.

## 2026-09-25

1. **Run the app in web mode.** The app now runs as a Flutter web app. Chrome
   debug mode lost its debug connection, so it runs on the `web-server` device
   at http://localhost:8080.
2. **Add Flutter support to devbox and the dev container.** Added `flutter` to
   devbox, plus a `devbox run web` script. The dev container got the Dart and
   Flutter extensions and forwards port 8080.
3. **Redesign the app UI as a surveillance app.** Removed the demo UI entirely.
   The screen now has two panels: a large Cameras panel on the left and an
   Events panel on the right. The Events panel has Settings (gear) and Login
   (person) buttons at its top right.
4. **Keep a software specification in `specs/`.** Created this folder. A rule
   in [CLAUDE.md](../CLAUDE.md) keeps it up to date with every request.
5. **Make `devbox services up` start the Flutter app in web mode.** Added a
   `2-flutter-web` process to process-compose. It runs
   `scripts/flutter-web.sh`, which `devbox run web` also uses, and has an HTTP
   readiness probe. The health monitor now checks the web app too.
6. **Open all device cameras in the Cameras panel.** Added the `camera` plugin.
   The panel opens every available camera and shows them as a grid of live
   tiles, with loading, empty and error states.
7. **Add a Clip button (camera icon) to the top of the Events panel.** It sits
   before Settings and Login, and is a placeholder for now.
8. **Update the spec on every prompt.** Saved as a standing rule for the
   assistant. The CLAUDE.md rule now covers every request.

Also fixed along the way: relaxed the Dart SDK constraint from `^3.13.4` to
`^3.13.0`, because the dev container's Nix Flutter 3.47.0 ships Dart 3.13.0.
9. **Run the app on an iPhone.** Blocked: this Mac has only the Command Line
   Tools (no Xcode), and no iPhone was connected. Added the iOS camera
   permission string (`NSCameraUsageDescription`) so the app can open cameras
   once it's installed on an iPhone.
10. **Separate the Events header buttons more, add a startup event, and make
    events scroll like a timeline.** The buttons are now tonal filled, 8 px
    apart. An "Application started" card is pushed on launch. Events show in a
    scrolling timeline, newest first, and scroll to the newest event when it
    arrives.
11. **Keep the Events panel a fixed size, with the Cameras panel taking the
    rest.** Removed the narrow-screen stacked layout. Events is always 360 px
    wide.
12. **Move the Clip button to the top of the Cameras panel.** It's now in the
    Cameras header. The Events header keeps Settings and Login.
13. **Restart the server.** Restarted the local Flutter web server on
    http://localhost:8080.
14. **Use the Gruvbox soft dark colors.** Added a Gruvbox palette and a
    matching Material theme, with the page on bg0_s `#32302f`. Camera tiles
    and labels use palette colors instead of black and white, and the web
    manifest colors match.
15. **Remove the marker beside each event and show just the card.** Removed
    the timeline dot and rail. Events are now a plain scrolling list of cards,
    newest first.
16. **Make the Cameras panel title the app title.** It now reads "Presence"
    and links to https://presence.nu01.com in a new tab. Added
    `url_launcher`.
17. **Review the code, commit and push.** The review found one bug: disposing
    a camera tile whose camera had failed to open raised an uncaught async
    error, because `CameraController.dispose()` rethrows the initialize
    error. Fixed. Verified in a freshly built dev container image: 13/13
    tests pass, the web build succeeds, and `devbox services up` brings the
    database and the web app up healthy.
18. **Where is the spec, and open it.** It lives in `specs/`. Opened
    `specs/README.md` in the editor.
19. **Is there a popular event bus for Flutter?** Answered: `event_bus` on
    pub.dev, or the more common alternatives (a broadcast `Stream`, Bloc,
    Riverpod). No change; the existing `EventLog` store stays for now.
20. **Always use a separate PR.** Added the rule to CLAUDE.md and saved it to
    the assistant's memory. Opened PR #1 for the app work; this rule ships in
    its own PR.
21. **Sync git.** Fetched from `origin`. Local and remote branches were
    already in sync.
