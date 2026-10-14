# Store readiness

What the App Store (iOS) and Google Play (Android) require that Presence
does and doesn't meet yet. Audited 2026-10-14 against the code on `main`.
Presence isn't in either store: Android ships as a side-loaded APK, iOS as
an unsigned development build ([Release builds](release.md)). The release
workflow can now make signed store builds (an `.aab` and an App Store
`.ipa`) once their keys are in its secrets ([Store
signing](release.md#store-signing)).

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
- **No privacy policy in the app.** The policy is at
  https://presence.nu01.com/privacy ([Legal](legal.md)) but the app
  doesn't link to it. Both stores want it in the app (Apple 5.1.1(i)) as
  well as in the listing.

## Blockers: App Store

- **Sign in with Apple, or an equivalent (4.8).** Google is the only
  sign-in. An app that uses a third-party login must also offer one that
  limits data to name and email, lets users hide their email, and doesn't
  track them. Sign in with Apple is the usual one.
- **No distribution certificate yet.** The release workflow builds an
  App Store `.ipa` (manual signing, `ExportOptions.plist` with
  `app-store-connect`) and uploads RC and GA builds to App Store Connect,
  but only once `APPLE_TEAM_ID`, an Apple Distribution certificate, an
  App Store provisioning profile (and, for the upload, an App Store
  Connect API key) are in its secrets ([Store
  signing](release.md#app-store-ios)). Until then it uploads an unsigned
  `Runner.app`.

## Blockers: Google Play

- **No upload key yet.** Release builds sign with an upload key from
  the environment or `android/key.properties`, and the release workflow
  builds an **Android App Bundle** signed with it, once the
  `ANDROID_UPLOAD_KEY*` secrets exist; a release bundle without a key
  fails rather than use the debug key. Still to do: create the key
  (`scripts/android-upload-key.sh`), set the secrets, turn on Play App
  Signing and upload the first `.aab` ([Store
  signing](release.md#google-play-android)). The `assetlinks.json` for
  [App Links](add-device.md), which the site doesn't serve yet, must then
  list Play's app signing certificate, and Google sign-in's Android
  client its SHA-1.
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
  - `ITSAppUsesNonExemptEncryption` isn't in `Info.plist`, so every
    upload asks. The app uses HTTPS and AES-256-GCM for its own media,
    which is usually exempt: set it to `false` once confirmed;
  - age rating;
  - review notes: a Google test account and how to get past the
    [consent](consent.md) screen, plus Premium access, or the reviewer
    can't see the features.
- **Permission texts (iOS):** `NSCameraUsageDescription` says the app
  "shows live feeds", but it records video always. Apple rejects texts
  that understate the use (5.1.1(ii)), so it should say it records clips.

## Risks

- **iPad.** `TARGETED_DEVICE_FAMILY = "1,2"`: it's reviewed on an iPad
  too, and needs iPad screenshots. It has only been run on an iPhone.
  Making it `1` (iPhone only) avoids this.
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
- **Permission texts** for camera, microphone and location are in
  `Info.plist`; no background modes are declared, so iOS doesn't expect
  background recording.
- **Icons:** Android adaptive and density icons; the iOS set includes
  the 1024 px marketing icon ([App icon](app-icon.md)).
- **Privacy policy and terms** are public at `/privacy` and `/tos`.
