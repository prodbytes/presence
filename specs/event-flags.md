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
  **flag** icon and, in yellow, what's unidentified ("Unidentified
  person", "Unidentified pet", "Unidentified person and pet", or
  "Unidentified person or pet" when one of two is named) followed by
  "· Identify". Its tooltip and screen-reader label: "Unidentified
  person/pet — identify". Long text is cut with an ellipsis, so it fits a
  320 dp phone and stays one line on wide screens.
- **Identify.** Tapping it opens the clip's player (as a label does)
  **paused where the first person or pet was seen**, with a yellow-flagged
  line "Unidentified person: click them on the video to name them, or try
  Auto." There the usual tagging works (see [Clips](clips.md), "Naming
  people and pets"): click them on the video and type a name ("Who is
  this?"), use **Tag this frame**, or **Auto**. A name typed as an
  existing subject's is that subject; a new one makes a new subject.
  Either way it's a vouched tag, so recognition learns them from it for
  the next clips, as before. Once everyone's named the line goes, and the
  flag leaves the card.
- A clip that can't be played (its recording not here yet) shows the flag
  without "· Identify", and tapping it does nothing.

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
  player paused at the sighting with the hint and Tag this frame, and a
  name added there clears hint and flag; a clip that can't play shows it
  without Identify; it fits at 320 dp and 1400 dp.

## Known limitations

- **Counts sorts, not individuals.** Two people seen and one named clears
  the flag; a person and a dog with two people named clears it too. A
  per-tag sort (person or pet) and per-frame counts would be needed to do
  better.
- The detector mixes up cats and dogs; both are pets, so it doesn't change
  the flag.
- Clips without object tags (recorded before them, or with them off) are
  never flagged until Auto tags them.
- The name prompt is free text: picking an existing subject means typing
  their name; it doesn't list the known subjects.
