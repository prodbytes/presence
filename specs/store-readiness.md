# Store readiness

What the App Store (iOS) and Google Play (Android) require that Presence
does and doesn't meet yet. Audited 2026-10-14 against the code on `main`,
and updated as items are fixed.
Presence isn't in either store: Android ships as a side-loaded APK, iOS as
an unsigned development build ([Release builds](release.md)). The release
workflow can now make signed store builds (an `.aab` and an App Store
`.ipa`) once their keys are in its secrets ([Store
signing](release.md#store-signing)).

## Blockers: both stores

- **Store billing needs its store setup.** The code is done: on iOS and
  Android [Premium](upgrade.md#on-ios-and-android-the-stores) is sold
  only as App Store and Google Play subscriptions (StoreKit 2, Play
  Billing), verified server-side by the [payments API](payments-api.md#store-purchases),
  with Restore purchases, Manage subscription and the terms and privacy
  links by the buttons (App Store 3.1.1, 3.1.2; Play's payments policy);
  Stripe stays on the web and is never shown, linked or named in the
  mobile apps. Still to do, outside the code: the subscriptions, trial
  and server notification URL in App Store Connect, the subscriptions,
  base plans, trial offer and service account in Play Console, and the
  deploy's `RBACR_GRANT_TOKEN` and `GOOGLE_PLAY_SECRET` ([Upgrade:
  Setting it up](upgrade.md#setting-it-up)).
  - The Terms of Service and the account deletion page, linked from the
    app, still name Stripe as the web's processor (not a link or a call
    to buy); App Review rarely objects to that, but it's a judgment call.

## Blockers: App Store

- **Getting in as a new account (3.1.1, 5.1.1): fixed (2026-10-16).** A
  signed-in user without membership could only subscribe at nu01.com,
  which stranded App Review and pointed to buying outside the app (Play's
  payments policy too). The iOS and Android sign-up sheet now has **Join
  free** in the app ([Membership](membership.md#getting-access-join-free-or-subscribe)),
  which the [payments API](payments-api.md#join-free) grants with the
  deploy's `RBACR_GRANT_TOKEN`; it mentions neither Premium's prices nor
  nu01.com. **The reviewer's path:** consent, Sign in (Apple or Google),
  the **Sign up** icon (top right), **Join free**, and the tabs appear;
  Premium is then in the Profile tab, bought in the sandbox. Step 3 of
  `store/app-store/review_notes.txt` says so. Needs `RBACR_GRANT_TOKEN`
  set on the GA deploy, or Join free answers 503.

- **Sign in with Apple (4.8): built, needs Apple's setup.** The iOS app
  offers Sign in with Apple beside Google, with equal prominence, asking
  only for name and email (private relay addresses work), on top of
  Presence's own [sessions](sessions.md); account deletion revokes the
  Apple tokens ([Sessions](sessions.md#sign-in-with-apples-revocation)).
  Still to do: enable Sign in with Apple on the App ID
  `com.nu01.presence` (the App Store profile must include it), create a
  Sign in with Apple key and put it in SSM
  (`APPLE_SIGNIN_KEY_ID`, `APPLE_SIGNIN_KEY_PARAMETER`), and give the
  review notes a way to sign in with Apple too.
- **Signing and upload: set up (2026-10-15).** The team (`LMX88986F3`)
  is a paid Apple Developer Program member, and the release workflow's
  secrets are all set: the Apple Distribution certificate, the App Store
  profile (with Sign in with Apple) and the App Store Connect API key
  ([Store signing](release.md#app-store-ios)); the files are kept in the
  private credentials repo. RC and GA builds are signed and uploaded to
  App Store Connect.
- **The app record:** "PresenceCam" (Apple ID `6823219680`, SKU
  `presence`, bundle ID `com.nu01.presence`, English (U.S.)), since
  "Presence" is taken in the App Store. The name under the icon stays
  "Presence". Its listing is pushed from the repo
  ([App Store listing](app-store-listing.md)).
- **Submitted to App Review (2026-10-16):** version 0.7.202610161834
  (build 1792175686) with the subscription group "Presence Premium" and
  both subscriptions, its first. Done before it: the Paid Apps
  agreement, banking and tax forms (active), the EU trader status (Digital
  Services Act), App Privacy (12 data types, all for app functionality,
  linked to the user, none for tracking), the review notes and contact.
  Still open in Business: the EU DAC7 information ("Missing Info"),
  which the account holder fills in.

## Blockers: Google Play

- **The developer account** (`nu01.com`, a personal account) is waiting
  for Google's identity verification (2026-10-16); Play Console creates no
  app until it passes. As a personal account made after November 2023, it
  must run a closed test with at least 12 testers for 14 days before
  production.
- **Upload key: made (2026-10-16).** The upload key is in the private
  credentials repo (`env.local/android/`), SHA-1
  `A3:AC:95:CD:30:67:EE:E7:46:29:A2:20:99:05:CF:D6:B5:A7:80:D9`, and the
  `ANDROID_UPLOAD_KEY*` secrets are set, so RC and GA releases build a
  signed `.aab`. Still to do once the account is verified: create the
  app, turn on Play App Signing and upload the first `.aab` ([Store
  signing](release.md#google-play-android)). The `assetlinks.json` for
  [App Links](add-device.md), which the site doesn't serve yet, must then
  list Play's app signing certificate, and Google sign-in's Android
  client its SHA-1.

## Declarations and reviews needed

- **Play Console:**
  - the release manifest asks only for what the app uses: camera,
    microphone, foreground location, notifications, the camera and
    microphone foreground services, wake lock, boot, battery
    optimization, network and billing (library extras are removed; see
    [Android](android.md));
  - foreground service types `camera` and `microphone`, with a video of
    the feature;
  - `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is restricted: only apps whose
    core function breaks under Doze may ask, with a justification (an
    always-on camera may qualify, but it's reviewed);
  - Data safety: email, name, photo and ID; precise location; photos,
    videos and audio; face features (biometric); app activity; logs;
    encrypted in transit; deletion in the app and at
    https://presence.nu01.com/delete-account (the deletion link);
  - content rating, target audience (16+, as the terms say), privacy
    policy URL.
- **App Store Connect:**
  - privacy labels, with the same data (face features count as
    sensitive);
  - age rating;
  - review notes: a Google test account and how to get past the
    [consent](consent.md) screen, plus Premium access, or the reviewer
    can't see the features;
  - while a build is in review, GA must take sandbox purchases
    (`STORE_ALLOW_SANDBOX=true`, [Payments API](payments-api.md#deploying)):
    the reviewer buys Premium in the sandbox with the production build;
  - the subscriptions submitted with the version; each has its review
    screenshot (the Premium plans, uploaded by the listing script).

## Risks

- **Surveillance apps** get a closer look in both stores (Apple 5.1.1,
  2.5.14: clear consent, and a visible or audible sign of recording).
  The consent screen helps; on Android the ongoing "Presence is
  recording" notification shows it in Unattended (screen off) too. iOS
  records only while the app is open and shown.
- **The name "Presence"** may already be taken in either store.

## Already met

- **Android target and compile SDK 36** (Flutter 3.47's defaults), above
  Play's current minimum (API 35); min SDK 24.
- **16 KB memory pages:** the only third-party native code, LiteRT 1.4.0
  (`libtensorflowlite_jni.so`, `libtensorflowlite_gpu_jni.so`), has
  16 KB-aligned arm64 segments.
- **Version codes** are the build time in Unix seconds, so they always
  go up, and stay under Play's limit (2,100,000,000) until 2036.
- **App IDs:** `com.nu01.presence` on both.
- **A persistent recording notice on Android** (Play's stalkerware and
  spyware policy): `POST_NOTIFICATIONS` is asked for at launch on
  Android 13+, and the foreground service's ongoing "Presence is
  recording" notification says it records the camera (and the
  microphone, when allowed), in Unattended and on the lock screen too
  ([Android](android.md)).
- **No background starts on Android 10+:** where Android blocks the
  watchdog and boot receiver from opening the app, they post "Presence
  stopped — tap to resume" instead (no `SYSTEM_ALERT_WINDOW` or
  `USE_FULL_SCREEN_INTENT`), and nothing starts the camera or microphone
  service from `BOOT_COMPLETED` (forbidden on Android 15).
- **Location** is asked only in the foreground (no background location).
- **iOS privacy manifests:** the app's own Swift code uses none of
  Apple's required-reason APIs. The Flutter engine and the plugins
  (`geolocator_apple`, `google_sign_in_ios`, `share_plus`,
  `url_launcher_ios`, `battery_plus`, `video_player_avfoundation`,
  `app_links`) ship their own. TensorFlowLiteC has none, but isn't on
  Apple's list of SDKs that must have one.
- **Icons:** Android adaptive and density icons; the iOS set includes
  the 1024 px marketing icon ([App icon](app-icon.md)).
- **Privacy policy and terms** are public at `/privacy` and `/tos`, and
  the app links to both (Apple 5.1.1(i)): the account sheet's About, the
  consent screen, and signed out the bottom of the camera
  ([About](about.md)); on iOS and Android also next to the store purchase
  buttons (Apple 3.1.2).
- **iOS permission texts** (5.1.1(ii)) say the camera records video
  continuously while the app is open and saves clips, the microphone
  records sound with it, and location is shown on a map and recorded
  with events; no background modes are declared, so iOS doesn't expect
  background recording ([iOS](ios.md)).
- **iPhone only** (`TARGETED_DEVICE_FAMILY = 1`): no iPad review or iPad
  screenshots.
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is `false`
  (HTTPS and AES-256-GCM for its own data are exempt), so uploads don't
  ask.
- **Account deletion** ([Account deletion](account-deletion.md)), since
  2026-10-14: the account sheet's **Delete account**, on every platform,
  deletes the account (the owner's whole profile and its cloud data, or a
  linked account's link) after a confirmation that says Premium isn't
  cancelled and links to how to cancel it (on iOS and Android, the
  store's subscription settings) (App Store 5.1.1(v)); and
  https://presence.nu01.com/delete-account explains how to ask without
  the app and what's kept, the link for Play's Data safety form. Before
  it works in AWS, the `presence-github-deploy` stack's permissions
  boundary needs updating by hand (identity deletion).
