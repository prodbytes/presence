# Recording consent

Before a device shows anything or records, it must have a **recording
consent**. Whoever sets it up confirms, once per device, that they may
record where it records, and that faces used to identify people are
biometric data under the GDPR. Once given, it isn't asked again on that
device.

## When it's asked

- At launch the app gets the [device ID](devices-users-places.md#devices)
  (making one on a first launch) and checks the device's consent. A spinner
  shows meanwhile. With no valid consent, the **consent screen** is all
  that shows. With one, the app starts as usual.
- **Nothing records before consent:** the cameras open (and the always-on
  recording starts) only once the consent is given or found.
- **Asked once:** a valid consent is never asked for again on the device.
  It's asked again only when:
  - the device's storage is cleared, which also makes a new device ID;
  - the consent was saved for another device ID;
  - the record was edited, so its hash doesn't match;
  - the text's version (`DeviceConsent.version`) is raised because what's
    agreed to changed.
- If the consent can't be read, the app asks. If it can't be saved, the
  app goes on for this session and asks again at the next launch.

## The screen

[lib/consent/consent_screen.dart](../presence_app/lib/consent/consent_screen.dart):
short, and one click to agree.

- **"Before Presence starts recording"**, then "By continuing, you
  confirm:".
- **Two highlighted conditions**, each in a tinted, outlined box with an
  icon, a bold statement and one plain line:
  - 📹 **"I have the right to record here."** I own or manage this place,
    or have permission, and people who may be filmed know about it.
  - 🙂 **"Faces are biometric data, and I am responsible."** Under the
    GDPR, faces used to identify people, as when naming them in clips,
    need care: clear consent, safe keeping, and deleting on request.
- **I agree**: one click accepts both and opens the app. There's no way
  past the screen without it, and nothing to tick.
- A small line says it's asked once on this device and isn't legal advice.
- On a small phone the screen scrolls if it must; it doesn't overflow.

## The record

- Saved in the `settings` store under `consent`
  ([lib/consent/device_consent.dart](../presence_app/lib/consent/device_consent.dart)):

  | Field | Value |
  |---|---|
  | `deviceId` | the device it was given on |
  | `version` | the consent text's version (1) |
  | `acceptedAt` | when, in milliseconds since the epoch |
  | `hash` | the verification hash: SHA-256 of `presence-consent\|v<version>\|<deviceId>\|<acceptedAt>` |

- It's valid only when its device ID is this device's, its version is the
  current one, and its hash matches its fields. The hash ties the consent
  to the device. It has no secret in it, so it catches mix-ups and edits,
  not deliberate forgery.
- Agreeing also publishes a **"Recording consent given"** event, with the
  device ID as its detail. Like every event it's stored, and it syncs for
  a signed-in user.

## Verified

- `consent_test.dart`:
  - a record is valid for its own device and version. Another device, an
    older version, an edited time, device or hash, or no record is not
    valid;
  - a new device shows only the consent screen, with both conditions and
    no checkboxes, and opens no camera; one click on **I agree** shows the
    app, opens the camera and saves a record whose hash checks out;
  - on a 360 × 640 screen it doesn't overflow and **I agree** is reachable;
  - after a relaunch the app opens straight away;
  - a consent saved for another device ID asks again.
- Other app tests skip the screen (`PresenceApp.consentGiven`, test-only).

## Known limitations

- The consent is per device, not per user or place, and isn't uploaded
  as a record of its own (only its event is).
- The text covers the EU's GDPR only, in general terms.
