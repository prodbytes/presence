# About

What Presence is, who makes it, its links, and a call to support it by
becoming a member ([lib/about.dart](../presence_app/lib/about.dart)).

- **Opened from the About icon** (`AboutButton`, `info_outline`, tooltip
  "About") in the app bar, which is always there: signed out, signed in
  without access, with access, and in DEV (see [Navigation](navigation.md)).
  It pushes a full screen (`AboutScreen`) with a back arrow, its content at
  most 640 px wide and scrolling.
- **Content**, top to bottom:
  - **Presence** and "Version X.Y.Z" (the build's [version](release.md);
    left out when the build has none);
  - what the app does, in a paragraph (as in the README), and a short
    reminder to make sure recording is allowed;
  - **"Made with ♥ by prodbytes"** (a heart icon in the error color);
  - the **support card**:
    - signed out: "Support Presence", why to become a member (every
      feature, cloud sync across devices, keeping Presence going), "Sign
      in first, then ask to become a member." and the Sign in with Google
      button;
    - signed in without access: the same, with **Become a member**, which
      opens the [Request access](membership.md) sheet;
    - a member: "Thank you for being a member";
    - none in DEV, which has no accounts.
    It follows sign-in and roles changes while open.
  - **Links**: Presence on the web (`https://presence.nu01.com`), Source
    code (`https://github.com/prodbytes/presence`), prodbytes
    (`https://prodbytes.substack.com`), and the License (Apache 2.0, no
    warranty). Tapping one opens it outside the app (`url_launcher`); a
    link that can't open is copied, saying "Link copied";
  - **Run it on this machine**: the [install script](install-script.md)'s
    command (`curl -fsSL https://sh.presence.nu01.com | sh`), selectable,
    with a Copy button.
- Tests: `about_test.dart` (the icon signed out, without access, and as a
  member at 320 and 1280 wide; the support card in each state; Become a
  member opening the request; links opening, or copied when they can't).
