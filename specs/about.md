# About

What Presence is, as a short paragraph at the **end of the account sheet**
(`AboutParagraph` in [lib/about.dart](../presence_app/lib/about.dart)).
There's no About button or screen any more, and no call to become a member.

- **Where:** the last thing in the [account sheet](sign-in.md) (the
  Account tab's page, or the sheet signed in without access), under a
  divider, after Sign out (or after the sign-in button or the "sign-in is
  unavailable" note). Neither is shown in DEV or to a signed-out user who
  can sign in, so there it isn't shown either.
- **Content**, small and quiet (`bodySmall`, muted):
  - one paragraph: Presence turns a phone, tablet, laptop or Raspberry Pi
    ([Raspberry Pi](raspberry-pi.md)) into an
    always-on camera for a place you look after (live feeds, clips that
    include the moments before, clips on motion), and to only record where
    you're allowed to;
  - "Presence is open source:" (no version: the build's version is at the
    bottom of [Settings](settings.md)) and a link to
    `github.com/prodbytes/presence`. Tapping it opens it outside the app
    (`url_launcher`); when it can't open, it's copied, saying "Link
    copied".
- Tests: `about_test.dart` (no About button signed in at 320 and 1280
  wide, or signed out; the paragraph after Sign out, with no membership
  pitch; the link opening, or copied when it can't).
