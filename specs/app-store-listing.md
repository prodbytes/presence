# App Store listing

The App Store product page is kept in the repo, in
[store/app-store/](../store/app-store), and pushed to App Store Connect
with [scripts/app-store-listing.mjs](../scripts/app-store-listing.mjs).

- **The app:** "PresenceCam" in App Store Connect (Apple ID
  `6823219680`), bundle ID `com.nu01.presence`, primary language English
  (U.S.). "Presence" was taken in the App Store; the home-screen name
  (`CFBundleDisplayName`) is still "Presence".
- **Per locale** (a folder named for it, e.g. `en-US/`, the only one so
  far): `name.txt` (30 characters at most), `subtitle.txt` (30),
  `privacy_url.txt` (the app's information, shared by all versions);
  `description.txt` (4,000), `keywords.txt` (100, comma-separated),
  `promotional_text.txt` (170), `support_url.txt`, `marketing_url.txt`
  (the version's). The description says the subscription's auto-renewal
  terms, and links the [terms and privacy policy](legal.md), as App Review
  asks of apps with auto-renewing subscriptions (3.1.2).
- **For all locales:** `copyright.txt`, and `age-rating.json`, the age
  rating questionnaire's answers (nothing objectionable, no
  user-generated content shared publicly, no web browsing), overridden to
  16+ as the [terms](legal.md) require.
- **Also set by the script:** categories Photo & Video (primary) and
  Utilities, and "doesn't use third-party content".
- **Running it:** `ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> node
  scripts/app-store-listing.mjs [version]`. The App Store Connect API key
  (team key, App Manager) is read from the private credentials repo
  (`../setec-astronomy/presence.nu01/env.local/apple/AuthKey_<id>.p8`, or
  `ASC_KEY_PATH`). It finds the one editable iOS version (preparing, or
  rejected) and its app information; with a version argument it renames
  that version to the build's `CFBundleShortVersionString`. It creates
  missing localizations and updates existing ones. `DRY_RUN=1` prints the
  changes without making them.
- **Screenshots** (since 2026-10-16): `en-US/screenshots/*.png`, five
  6.9" iPhone screenshots (1320x2868, PNG without alpha), shown in name
  order: the camera, the events with their map, Setup, the Profile tab
  with the Premium plans, and the consent screen. The script puts them in
  the version's 6.9" slot (`APP_IPHONE_67` in the API, which also takes
  1290x2796; the App Store scales it for smaller iPhones; iPhone only, so
  no iPad set), replacing what's there: it reserves each screenshot, uploads
  its parts as Apple's upload operations say, commits it with its MD5,
  orders the set and waits until each is `COMPLETE`. A set that already
  has exactly these files (by MD5) is left alone, so it can run again.
  - `subscription-review.png` (the Profile tab's Premium plans, the same
    picture) is each Premium subscription's App Review screenshot
    (`presence.premium.monthly`, `presence.premium.yearly`), replaced the
    same way unless it's already that file.
  - `SCREENSHOTS_ONLY=1` uploads only the screenshots.
  - They're made by [scripts/app-store-screenshots.sh](../scripts/app-store-screenshots.sh):
    it runs
    [integration_test/store_screenshots_test.dart](../presence_app/integration_test/store_screenshots_test.dart)
    on the newest "Pro Max" iPhone simulator (host Flutter) with Apple's
    9:41 status bar, and takes a screenshot at each `SHOT <name>` the test
    prints (`xcrun simctl io screenshot`), flattened to RGB (ffmpeg, or
    sips). The test runs the real app with fakes: a made-up account
    (Alex Rivera, alex@example.com, free), a camera showing a photo of
    Suerte from `test/data/`, four demo clips from those photos in Golden
    Gate Park (a public place), and the App Store's two plans at their US
    prices ($20.00 a month with a week free, $200.00 a year). No real
    account, place or personal data.
- **Not in the script** (App Store Connect's web pages, or the account
  holder): App Privacy, the price and availability, the review contact
  and notes, the subscriptions themselves, and submitting.
