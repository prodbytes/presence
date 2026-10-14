# Store readiness

What the App Store (iOS) and Google Play (Android) require that Presence
does and doesn't meet yet. Audited 2026-10-14 against the code on `main`,
and updated as items are fixed.
Presence isn't in either store: Android ships as a side-loaded APK, iOS as
an unsigned development build ([Release builds](release.md)).

## Blockers: both stores

- **Premium is sold through Stripe.** [Upgrade](upgrade.md) opens a
  Stripe checkout for a digital subscription (cloud backup, more devices).
  - App Store 3.1.1: outside the US storefront, the app may not link to
    or offer another way to buy (the EU, Japan and Brazil allow it with an
    entitlement, and Apple still takes a commission). In the US storefront
    a link out is allowed (since May 2025).
  - Google Play: Play Billing, unless the developer is enrolled in the
    alternative billing or external-links programs (the US, the UK and
    the EEA from 2026-06-30, with a service fee).
  - Either way, it needs store products and a server that checks
    purchases and grants `premium` in rbacr, or hiding the buttons in
    store builds (and selling only on the web, without mentioning it in
    the app).
- **No account deletion.** Users can delete devices and events, not their
  account and profile. The privacy policy only offers deletion on request
  by email.
  - App Store 5.1.1(v): an app with sign-in must let users start deleting
    their account in the app.
  - Google Play: the same in the app, plus a web link where users can ask
    for deletion without the app, given in the Data safety form.

## Blockers: App Store

- **Sign in with Apple, or an equivalent (4.8).** Google is the only
  sign-in. An app that uses a third-party login must also offer one that
  limits data to name and email, lets users hide their email, and doesn't
  track them. Sign in with Apple is the usual one.
- **No distribution signing.** Builds are signed with a development
  identity (team `LMX88986F3`) by Flutter; the release workflow uploads an
  unsigned `Runner.app`. App Store builds need a distribution certificate,
  an App Store provisioning profile, an `.ipa` archive and an upload
  (Xcode, `xcrun altool` or Transporter).

## Blockers: Google Play

- **Release builds use the debug key** (`signingConfig =
  signingConfigs.getByName("debug")` in `android/app/build.gradle.kts`).
  Play rejects debug-signed uploads. It needs an upload key (outside git),
  Play App Signing, and an **Android App Bundle** (`flutter build
  appbundle`); the release workflow builds an APK only. The
  `assetlinks.json` for [App Links](add-device.md) must then list Play's
  app-signing certificate.
- **The capture notification is hidden on Android 13+.** The app doesn't
  ask for `POST_NOTIFICATIONS`, so "Presence is capturing" doesn't show
  ([Android](android.md#known-limitations)). An app that records camera
  and microphone with the screen off (Unattended), reopens itself at boot,
  and shows no notice risks Play's stalkerware and spyware policy, which
  requires a persistent notice while recording.

## Declarations and reviews needed

- **Play Console:**
  - foreground service types `camera` and `microphone`, with a video of
    the feature;
  - `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is restricted: only apps whose
    core function breaks under Doze may ask, with a justification (an
    always-on camera may qualify, but it's reviewed);
  - Data safety: email, name, photo and ID; precise location; photos,
    videos and audio; face features (biometric); app activity; logs;
    encrypted in transit; deletion;
  - content rating, target audience (16+, as the terms say), privacy
    policy URL.
- **App Store Connect:**
  - privacy labels, with the same data (face features count as
    sensitive);
  - age rating;
  - review notes: a Google test account and how to get past the
    [consent](consent.md) screen, plus Premium access, or the reviewer
    can't see the features.

## Risks

- **Surveillance apps** get a closer look in both stores (Apple 5.1.1,
  2.5.14: clear consent, and a visible or audible sign of recording).
  The consent screen helps; the screen-off Unattended mode should still
  show that it's recording.
- **Starting itself on Android 10+.** The watchdog and boot receiver
  open the activity from the background, which Android 10+ blocks (it's
  logged). That isn't a policy issue, but it means the feature doesn't
  work on new phones. On Android 15 a boot receiver may not start a
  camera or microphone foreground service either.
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
  ([About](about.md)).
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
