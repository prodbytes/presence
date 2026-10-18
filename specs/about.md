# About

What Presence is, as a short paragraph at the **end of the account sheet**
(`AboutParagraph` in [lib/about.dart](../presence_app/lib/about.dart)).
There's no About button or screen any more, and no call to become a member.

- **Where:** the last thing in the [account sheet](sign-in.md) (the
  Profile tab's page, or the sheet signed in without access), under a
  divider, after Sign out (or after the sign-in button or the "sign-in is
  unavailable" note). Neither is shown in DEV or to a signed-out user who
  can sign in, so there it isn't shown either.
- **Content**, small and quiet (`bodySmall`, muted):
  - one paragraph: Presence turns any device with a camera into an
    always-on camera for a place you look after (live feeds, clips that
    include the moments before, clips on motion), and to only record where
    you're allowed to;
  - "Presence is open source:" (no version: the build's version is at the
    bottom of [Settings](settings.md)) and a link to
    `github.com/prodbytes/presence`. Tapping it opens it outside the app
    (`url_launcher`); when it can't open, it's copied, saying "Link
    copied".
  - **"Privacy Policy · Terms of Service"** (`LegalLinks`), two small
    links to the site's `/privacy` and `/tos` ([Legal](legal.md)), opened
    the same way.
- **The legal links elsewhere:** on the [consent](consent.md) screen,
  under **I agree**; and signed out (no account sheet then), centred at
  the bottom of the camera on a dark scrim (`SignedOutLegalLinks`), where
  nothing else is shown signed out. With access they're only in the
  Profile tab's About. So they're reachable signed in and out, on every
  platform.
- **Where they point:** the same site as the app's API
  (`ApiConfig.baseUrl`, `LegalPages`): the page's own origin on web, and
  on Android and iOS `API_BASE_URL` (the RC's site in RC builds) or
  https://presence.nu01.com.
- Tests: `about_test.dart` (the paragraph after Sign out at 320 wide,
  with no membership pitch; the link opening, or copied when it can't;
  the legal links in the account sheet, on the consent screen at 360 ×
  640, and signed out at the bottom of the camera, each opening `/privacy`
  and `/tos`; none over the camera with access).
