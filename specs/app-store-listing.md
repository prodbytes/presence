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
- **Not in the script** (App Store Connect's web pages, or the account
  holder): screenshots, App Privacy, the price and availability, the
  review contact and notes, the subscriptions, and submitting.
