# Event flags

An event can carry **flags**: things about it that want attention, shown
on its card beside what was detected on it (its subjects and object tags)
([lib/event_flags.dart](../presence_app/lib/event_flags.dart)).

## Flags in general

- `EventFlag` lists them; each has a color and a tooltip. `AppEvent.flags`
  gives an event's flags; most events have none, and a clip
  (`ClipRequested`) works out its own from its tags and object tags
  (`flagsOf`).
- **Derived, never stored.** Flags are worked out from the event's data
  each time they're shown, so they change as soon as the data does (a tag
  added here, by recognition, or synced from another device). Nothing is
  added to the event's record or JSON (see [Data formats](data-formats.md)).
- The Events **search** matches a flag's name: "unidentified" finds the
  flagged clips (see [Events](events.md)).
- A new flag is one more value of `EventFlag`, and a line in the
  clip's `flagsOf` (or another event type's `flags`).

## Unidentified

A clip is flagged **unidentified** when it shows a person or a pet that
isn't identified as a known [subject](subjects.md): all people and pets
should be named.

- **Who counts.** What [recognition](recognition.md) saw on the clip, its
  object tags:
  - **people:** `human` (the detector's `person`);
  - **pets:** `cat` and `dog`, the household pets the detector knows, and
    the sorts recognition matches pets of. Its other animals (bird, horse,
    sheep, cow, elephant, bear, zebra, giraffe) and every other object
    aren't flagged.
- **When.** Object tags keep which kinds were seen, not how many, and a
  name tagged on a clip doesn't say whether it's a person or a pet. So a
  clip is unidentified while it has **fewer subjects named on it than
  sorts seen** (a person, a pet, or both: 1 or 2). Named means a tag:
  made by someone, recognized automatically, or a suggestion someone
  confirmed; a suggestion still waiting for its "Is this Rex?" answer
  isn't. Tags of the same name (ignoring case and spaces) are one subject.
  - A person seen, nobody named: flagged. Name one: cleared.
  - A person and a dog seen, one name: still flagged ("person or pet");
    a second name: cleared.
  - Removing the name (its **x** on the card) flags it again.
  - A clip not searched for objects yet, or with object tags off, isn't
    flagged: nothing says who's there.
- **On the card** (`EventFlags`, key `event-flag-unidentified`), under the
  object tags: a small pill edged in **Gruvbox yellow** with a yellow
  **flag** icon and, in yellow, **"Unidentified subject · Identify"**
  (people and pets are both subjects, as the Monitoring screen calls
  them). Its tooltip and screen-reader label: "Unidentified subject —
  identify". Long text is cut with an ellipsis, so it fits a
  320 dp phone and stays one line on wide screens.
- **Identify.** Tapping it opens the clip's player (as a label does)
  **paused where the first person or pet was seen**, with a yellow-flagged
  line "Unidentified subject: click them on the video to name them, or try
  Auto." There the usual tagging works (see [Clips](clips.md), "Naming
  subjects"): click them on the video and type a name ("Who is
  this?"), use **Name subject**, or **Auto**. A name typed as an
  existing subject's is that subject; a new one makes a new subject.
  Either way it's a vouched tag, so recognition learns them from it for
  the next clips, as before. Once everyone's named the line goes, and the
  flag leaves the card.
- A clip that can't be played (its recording not here yet) shows the flag
  without "· Identify", and tapping it does nothing.

## Who is this?

The flag waits on the clip's card; this asks. When recognition can't
name a person or pet it saw, a **"Who is this?"** event
(`SubjectRequest`, [lib/recognition/subject_request.dart](../presence_app/lib/recognition/subject_request.dart))
in the events asks the user to tag them, as "Is this Rex?" asks when it
is unsure.

- **When.** At the end of an automatic recognition run on a clip (a new
  clip, a synced or streamer clip this device searches), once its search
  for subjects has ended, if the clip is **unidentified** (above) and no
  "Is this Rex?" was asked on it: that question already asks for a name.
  Not after **Auto** in the player, which shows the identify hint there.
  **Once per clip**: not again if the clip is searched again, or a
  request about it is already in the history (any device's).
- **The event** (`type: subject_request`): `clipEventId`, `sorts`
  (`person`, `pet`, or both) and `ms`, where the first of them was seen.
  Saved, synced, and deleted with its clip like a suggestion; linked to
  its clip on restore. A grab, so it shows with system events hidden,
  and the search finds it by "Who is this?", its detail and its camera.
- **The card**, top to bottom: the clip's thumbnail (180 px wide,
  tapping it identifies); the person-add icon and **"Who is this?"**;
  "A person was seen" ("A pet was seen", "A person and a pet were seen")
  · camera · time; and **Identify** (key `request-identify`), which opens
  the player paused where they were first seen, with the identify hint,
  as the flag's **Identify** does.
- **Answered** once the clip isn't unidentified any more (named in the
  player, from the flag, by recognition, or on another device): the
  question's place shows "✓ **Named Ana, Rex**" with their color squares,
  and Identify goes. Removing the names brings the question back.
- Its clip not here yet: "The clip isn't here yet" instead of Identify;
  its clip gone: "The clip is missing".

## Verified

- `event_flags_test.dart`: an unknown person flagged, its first sighting
  kept; an unknown cat or dog flagged (at the dog's sighting, not an
  earlier car's); other animals, objects, nothing seen or not searched not
  flagged; everyone named (by someone or recognized) not flagged; a person
  and a pet need a name each, the same name twice counts once; a
  suggestion identifies only once confirmed; tagging clears it and
  removing the tag brings it back; the search finds flagged clips. The
  card shows the yellow flag with its text, tooltip and semantic label and
  drops it once tagged; none without a person or pet; Identify opens the
  player paused at the sighting with the hint and Name subject, and a
  name added there clears hint and flag; a clip that can't play shows it
  without Identify; it fits at 320 dp and 1400 dp.
  `recognition_test.dart`: "Who is this?" asked once about a clip with an
  unnamed person and dog (both sorts, the first sighting's time, not an
  earlier car's), a grab, found by the search; not again on a second run
  or Auto; not for a named clip, a clip with only a bicycle, or on Auto;
  the event round-trips and rejects unknown sorts; its card asks,
  Identify opens the player at the sighting with the hint, a name
  answers it ("Named Ana"), and without its clip it says so.

## Known limitations

- **Counts sorts, not individuals.** Two people seen and one named clears
  the flag; a person and a dog with two people named clears it too. A
  per-tag sort (person or pet) and per-frame counts would be needed to do
  better.
- The detector mixes up cats and dogs; both are pets, so it doesn't change
  the flag.
- Clips without object tags (recorded before them, or with them off) are
  never flagged until Auto tags them.
- "Who is this?" is asked only by the device that ran recognition, and
  only in the events: there are no push notifications.
- The name prompt is free text: picking an existing subject means typing
  their name; it doesn't list the known subjects.
