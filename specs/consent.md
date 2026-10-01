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

[lib/consent/consent_screen.dart](../presence_app/lib/consent/consent_screen.dart),
in plain terms:

- **"Before Presence starts recording"**: the app records video and sound
  all the time, and lets you name people in clips. It's asked once on
  this device.
- **"You may record here"**: you own or manage the place, or have
  permission to record it. The people who may be filmed know about it
  (for example from a sign, where the law asks for one). Recording where
  people expect privacy, or without the right to, can be illegal.
  - Tick: **"I have the right to record where this device records."**
- **"Faces are biometric data"**: a recording of someone is personal data.
  When their face is used to recognise or identify them, as when naming
  people in a clip, the GDPR counts it as biometric data, a sensitive kind
  with stricter rules. Usually that means the people must have clearly
  agreed, recordings are kept safe and only as long as needed, and anyone
  can ask to see or delete what's about them. The user is responsible.
  - Tick: **"I understand that faces used to identify people are biometric
    data under the GDPR, and that I am responsible for using them
    lawfully."**
- **Agree and start** turns on only with both ticks. There's no way past
  the screen without agreeing.
- A small note says it isn't legal advice.

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
  - a new device shows only the consent screen and opens no camera;
    **Agree and start** needs both ticks; agreeing shows the app, opens
    the camera and saves a record whose hash checks out;
  - after a relaunch the app opens straight away;
  - a consent saved for another device ID asks again.
- Other app tests skip the screen (`PresenceApp.consentGiven`, test-only).

## Known limitations

- The consent is per device, not per user or place, and isn't uploaded
  as a record of its own (only its event is).
- The text covers the EU's GDPR only, in general terms.
