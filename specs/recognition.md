# Subject recognition

Every new clip is searched in two segments, fed by the same frames and the
same detector pass ([lib/recognition/](../presence_app/lib/recognition)):

- **Subjects**, who has an identity (the person Julio, the dog Fido): the
  [subjects](subjects.md) someone tagged on earlier clips. Whoever is
  recognized surely is tagged on the clip; whoever only might be is asked
  about.
- **Object tags**, what was there, with no identity, for search later
  ("clips with cats and bicycles"): `human`, `cat`, `dog`, `bicycle`,
  `bottle` and the rest of the 80 kinds of object the detector knows.

## When it runs

- On each **new clip** (pressed, motion, scheduled or startup), once it's
  **fully recorded** (before + after) and saved. Only then is it queued:
  clips run one at a time, in the background, on the device that recorded
  them, and one still recording doesn't hold up the others (nor Auto on
  another clip). Restored and synced clips aren't run.
- **Backpressure:** at most the **latest 3 new clips** wait their turn;
  when another arrives the oldest waiting one is skipped (logged, outcome
  `deferred`). Auto is never skipped, and goes ahead of the new clips
  waiting (after the clip already running).
- **Memory (Android):** before a clip's models run, the app asks Android
  how much memory is left (`memoryStatus`, see [Android](android.md)). It's
  **tight** when the system says memory is low, or less than its
  low-memory threshold plus 96 MB is free (the models' files are 26 MB,
  the detector's working memory and a 1280 px frame the rest). Then the
  models are freed and a new clip steps out of the queue for 30 s and
  asks again, up to 10 times (5 min) before it's skipped; it holds
  nothing up meanwhile. Auto doesn't wait but says the phone is low on
  memory. After
  each clip, tight memory frees the models at once; otherwise they're
  freed after **60 s** without a frame, and loaded again for the next
  clip. Elsewhere there's no such check.
- A new clip already searched with **Auto** while it was recording isn't
  searched again once it's done (it has its object tags by then, too).
- Only on a platform that has the runtime: **web** and **Android**. iOS
  comes next, with the same models (see [Platforms](platforms.md)).
- **On request, on any clip:** the player's **Auto** button (see
  [Clips](clips.md), "Naming subjects") runs the same search on the
  clip it shows: restored and synced clips too, and even with **Recognize
  subjects in new clips** off. It runs on the device, after any clip
  already being searched, and waits for the full recording if it isn't
  saved yet.
- **Subjects** only with **Recognize subjects in new clips** on (or on
  request), and only when some subject has a **reference**: a tag someone
  made, or a suggestion someone confirmed, with its frame.
- **Object tags** only with **Tag objects in new clips** on (Settings,
  default on; or on request), and only on a clip not searched for objects
  yet: once it has its object tags (even none), it isn't searched for them
  again, not even by Auto. They need no references.

## How

How each choice was measured (datasets, numbers) is in the models'
[README](../presence_app/assets/models/README.md#how-they-were-chosen-2026-10-06).

1. **References.** For each subject, their latest 10 vouched tags (made or
   confirmed by someone, never recognized ones, so a mistake can't spread).
   On each tag's frame, the person, cat or dog **containing the clicked
   spot** (the smallest such box; else the nearest within 15 % of the
   frame) is the reference. Its embeddings are kept in memory for the
   session, never stored or synced; those of tags no longer in the log
   (deleted, or past retention) are dropped, as are the searched-clip
   marks of clips no longer in it.
2. **Frames.** The clip is sampled **every 1 s**, from its start to its
   end, at most **1280 px** wide (reference frames too; a 720p recording
   whole), so far faces keep every pixel. On Android each sample is the
   **keyframe** nearest to its time (the recorder makes one a second),
   each once, at its own time, and only those inside the clip: a keyframe
   decodes on its own, where any other frame needs the frames since the
   last keyframe. Where a frame is shrunk for a model, each value is the
   mean of the pixels it covers (not one sample), so nothing between
   samples is skipped.
3. **Who's there.** On each frame, **EfficientDet-Lite2** (448 px) runs on
   the **whole frame** (in a square, black around it, not stretched) and,
   for a wide frame (or a tall one), on **overlapping squares** along it
   as tall as the frame (2 for 16:9), where far people and things are
   twice as big. Its anchors are the ones the model file lists. Each run
   scores every COCO class on every anchor, once, for both segments:
   - **object tags:** each of the 80 labels scoring **0.5** or more
     somewhere on the frame (any of its squares), with its best score
     (`person` is `human`);
   - **subjects** (while someone's still to be found): its people, cats
     and dogs (score 0.4 or more), from all the squares, merged (a box
     overlapping a better one of its kind by more than half, or 80 %
     inside it, as a tile cuts someone at its edge, is the same one); of
     the sorts some reference is (people if a person is known, cats and
     dogs if a pet is), the **best 5** per frame. For each person
     **BlazeFace** looks for a face (only if some reference has one):
     first in a **square around their head** (as wide as they are, at
     least 7/16 of their height, from just above their top), else in a
     square around all of them, kept only in their top 35 %. A face whose
     eyes are **9 px** apart or more (on the frame) is **aligned** to the
     template **MobileFaceNet** was trained on (eyes, nose and mouth moved
     to their places by turning, scaling and moving it) and embedded,
     averaged with its mirror image; a smaller one is too blurred to tell
     people apart, so only its spot is kept. Everyone gets a **look**
     embedding: **OSNet** (trained to tell people apart) for people, from
     their box; **MobileNetV3** for cats and dogs, from a square around
     them. Once every subject is surely found, frames only go through the
     detector.
4. **Matching.** Each person or pet is compared with every reference of the
   same sort (people with people, pets with pets): **by face** when both
   show one, **by look** otherwise. The cosine similarity becomes a
   **confidence** from 0 to 1:
   - faces: 0 at 0.30, 1 at 0.65 (aligned, different people score under
     0.44, the same person 0.62–0.75 typically);
   - people's looks (OSNet): 0 at 0.53, 1 at 0.82;
   - pets' looks (MobileNetV3): 0 at 0.45, 1 at 0.90.

   Pairs are made surest first, one subject per person and one person per
   subject on a frame.
5. **Over the clip.** Each subject's confidence is their **surest face**
   match, or else the **mean of their best 3 frames** (of the frames they
   were paired on; fewer if they were on fewer), whichever is higher. One
   lucky look of a stranger counts less than someone seen again and
   again, while an aligned face is enough on its own (different people's
   score under the ask floor 99.9 % of the time). A subject with a face at
   the auto-tag level, or 3 frames there, is surely found, and isn't
   looked for on later frames.
6. **Tag, ask, or neither** (the threshold in Settings), once the clip is
   done:
   - from **Tag automatically** (default **85 %**): a **recognized tag**
     (`source: detected`, with that confidence) on their **best frame**,
     at the face's center (or the box's);
   - below it, always asked: from **30 %** (`RecognitionConfig.askFloor`,
     not a setting) up, a **suggestion** (`source: suggested`) on their
     best frame, and a **"Is this Rex?"** event (`SubjectSuggestion`);
   - under 30 %: nothing. (There used to be an **Ask me** slider, default
     50 %; it's gone, and stored `ask` values are ignored.)

   A subject is tagged or asked about at most once per clip. Subjects
   already on the clip are skipped.
7. **Object tags:** each label is kept **once per clip**, if seen on **2
   frames** or more, or on one at **0.7** or more (or on a clip of one
   frame): a label on one frame only, unsure, is more often a mistake than
   a thing seen for an instant. It keeps the **first frame** it was seen
   on (`ms` into the recording) and its best score. The whole clip is
   sampled for them, then they're stored together, in order of first
   sighting.

## Object tags

- Kept with the clip, in `ClipAnnotations.objects`, saved in its record as
  `objectTags: [{label, ms, score}]`, and synced in the event JSON like its
  subject tags. No `objectTags` means not searched yet; `[]` means
  searched, nothing seen. Malformed entries are skipped on restore.
- They're the clip's **Tags**, the user-facing name, as opposed to its
  **Subjects** (named people and pets). The player lists them under a
  "Tags" heading (see [Clips](clips.md), "Subjects and Tags").
- The clip's card shows them as small outlined chips under its subjects
  ("human", "bicycle"), in order of first sighting. Each keeps where it was
  first seen (`ms`, in the recording's time, like a tag's `frameMs`), and
  clicking it opens the player paused on that frame (see
  [Clips](clips.md)); in the Monitoring tab's timeline that's a long
  press, and a click filters the events by the tag, highlighting it while
  it's the search (see [Events](events.md)). Only the time is kept, not the frame's image.
- **Removing one:** the **x** inside each chip (key
  `clip-object-remove-<label>`, tooltip "Remove tag bicycle from this
  event")
  removes that label from the clip (`ClipAnnotations.removeObject`), at
  once and without asking. The search and the Events count update, and
  the record is saved and synced; with none left it keeps `[]` (searched),
  so the clip isn't searched for objects again on its own. The player's
  **Auto** can find it again.
- The Events **search** matches them: "bicycle" finds the clips with a
  bicycle (see [Events](events.md)).
- A `human`, `cat` or `dog` with nobody named on the clip flags it
  **unidentified** (yellow, with **Identify**; see [Event
  flags](event-flags.md)).
- They're labels, not subjects: no names, colors, maps, references or
  questions, and they never make anyone a subject.

## Auto, in the player

- **Auto** (✨) sits beside **Name subject** under the player's
  "Subjects" heading. While it runs it shows a spinner and "Looking for
  the subjects named before…" ("Waiting for the clip to finish recording…" first, if
  needed). Then it says what it did:
  - "Found Rex and Ana." for the recognized subjects, which appear in the
    list at once;
  - "Not sure about Bo: answer "Is this Bo?" in the events." for the
    suggestions (each with its question event, as for new clips);
  - "No subjects recognized.", "Every subject named before is already on
    this clip." (subjects already on it, suggestions included, are
    skipped), or "No subjects to look for yet: name someone on another
    clip first." (no
    reference shows anyone where it was clicked);
  - "Couldn't run recognition; try again." if the models didn't load;
  - "The phone is low on memory: try again in a moment." when memory is
    tight (Android);
  - followed by "Tags: cat, bicycle." when it tagged objects (only on a
    clip without tags yet); they show in the Tags section at once.
- Where recognition can't run (Android and iOS for now) the button is
  disabled, with the tooltip "Not available on this device yet".
- Each run returns a `RecognitionResult` (`SubjectRecognizer.recognizeNow`):
  its outcome for subjects, the names tagged and asked about, and the
  object labels tagged. The app reaches the
  recognizer through `SubjectRecognizerScope`, above `MaterialApp`.

## The question

- The **"Is this Rex?"** card in the events shows the frame with a dot in
  Rex's color where they were seen, "62 % sure · Back camera", and **Yes,
  it's Rex** / **No**.
- **Yes** makes the suggestion a tag (`source: confirmed`), which then also
  becomes one of Rex's references. **No** removes it. The card then says
  "Tagged as Rex" or "Not Rex".
- Suggestions aren't tags until confirmed: they're left out of the clip's
  card, the player's list, the maps and the subject's screen.
- The event (`type: subject_suggestion`, with `clipEventId`,
  `annotationId`, `subjectName`, `confidence`) and the suggestion (in the
  clip's `annotations`, with its frame) are saved and synced like other
  events and tags; the answer is the suggestion's state, so it's kept too.

## Recognized tags

- Shown like any tag, with ✨ (`auto_awesome`) beside the name on the clip's
  card ("Recognized automatically") and on the player's chip, which also
  shows the confidence ("Rex · 86 %"). They can be renamed or removed like
  any tag.

## Platforms

- **Shared Dart** (`vision.dart`, `matching.dart`, `recognizer.dart`):
  pre-processing (bilinear sampling averaged over what each value covers,
  crops, rotation, face alignment, the detector's squares), EfficientDet's
  anchors, box decoding, merging and labels (`cocoLabels`, `decodeObjects`;
  `VisionModels.analyse` returns a `FrameAnalysis` of both), BlazeFace's anchors, non-maximum suppression,
  matching and thresholds. Each platform only runs the models and reads
  frames, so all give the same results.
- **Web:** **TensorFlow.js** with `@tensorflow/tfjs-tflite` (TensorFlow
  Lite in WebAssembly, SIMD), served from `/app/tfjs/` with the app and
  loaded on first use (see [web/tfjs/README.md](../presence_app/web/tfjs/README.md));
  frames from a hidden, muted `<video>` seeked through the recording and
  drawn on a canvas.
- **Android:** **LiteRT** (TensorFlow Lite, `com.google.ai.edge.litert`
  1.4.0) through Google's **`tflite_flutter`** plugin (0.12.1, Dart FFI),
  2 CPU threads. One long-lived **worker isolate** (`vision_worker.dart`,
  `WorkerVision`) owns the five models: it loads them (mapped from files
  the assets are copied to, so nothing is held twice and nothing leaks
  when they're freed), builds the anchors, resizes each frame to each
  model's input, runs them and decodes their outputs, reading
  EfficientDet's 13.5 MB of scores in place. The app's isolate only sends
  each frame's RGBA pixels (`TransferableTypedData`: copied once into
  the transfer, then moved to the worker) and gets back who's on it,
  so it doesn't stall. Frames come from `keyframesAt` on the
  `presence/cameras` channel, 3 times per call, as raw RGBA; a frame's
  JPEG is only made (`encodeJpeg`) when a tag or suggestion keeps it.
  Reference frames (JPEGs) are still decoded by the engine
  (`instantiateImageCodec`). See [Android](android.md).
- **iOS:** not yet (the switch says "Not available on this device yet").
  `tflite_flutter` supports iOS, so it needs `keyframesAt` and
  `encodeJpeg` in Swift; the iOS app already links its `TensorFlowLiteC`
  2.12 through CocoaPods.
- **Models** (`assets/models/`, 26 MB; on web fetched only when
  recognition first runs, in the Android app bundled): see [assets/models/README.md](../presence_app/assets/models/README.md)
  for sources, checksums and licenses.

## Verified

- `recognition_test.dart`: EfficientDet and BlazeFace decoding (with the
  nose and mouth); EfficientDet's anchors equal to those its model file
  lists; the detector's squares (whole frame, and tiles along a wide or
  tall one); detections from them merged, cut-off parts dropped, other
  kinds kept; object labels (80, `human` for people, best score once,
  unsure and unused classes left out); pixel scales, rotation and black
  outside the picture; a shrunk picture averaged over what each value
  covers; mirroring; the head's square; a face's region aligning it to
  the template (turned, scaled and moved, with or without nose and mouth);
  faces under the eye distance minimum; confidence scales; faces
  compared when both show, looks otherwise, people never matched to pets;
  one subject per person, surest first; a tag picks the smallest detection
  around it; settings limits and round-trip; tag sources and confidences
  round-trip, suggestions not tags nor subjects; the suggestion event
  round-trip; the recognizer (fake models) tags a sure match on their
  best frame, asks about an unsure one (pooled over the clip) on their
  best frame (a JPEG per frame someone was best on), asks about a stranger
  with one lucky look rather than tagging them, tags on one sure face
  whatever the other frames, stops once everyone's surely found (a sure
  face at once, or 3 sure looks), skips who's tagged, never learns from
  recognized tags, and does nothing when off; the card's Yes and No; on
  request it runs even when off and reports who it tagged and asked
  about, then that everyone is on the clip; a new clip published while
  recording isn't searched until its full recording is done, Auto on
  another clip runs meanwhile, and its subject is tagged once, on a
  frame they're on; a new clip searched with Auto isn't searched
  again; nobody to look for (none
  tagged, or the tag points at nobody) and nobody found; a failed model
  load doesn't block the next run; only the sorts of subject known are
  embedded, at most 5 detections a frame (`keepDetections`); only the
  latest 3 new clips wait (older ones skipped, Auto never); Auto goes
  ahead of the new clips waiting; tight memory
  puts Auto off and frees the models, and makes a new clip wait until
  there's room or give up after its retries, without holding up Auto; what counts as tight; object
  tags: each label once, from its first frame with its best score, over
  the whole clip, with nobody to look for, and not again once searched;
  one seen on a single frame unsure is dropped, sure kept, and a one-frame
  clip keeps what it saw; they keep going after every subject is found
  (subjects only embedded until then); off in Settings, none stored; their record
  round-trip (absent, empty, malformed); the clip's card shows them; the
  card's object tags and subject names open the player paused at their
  first frame (the subject's earliest; from the start without a frame),
  kept inside the clip window; the
  player's Auto tags a sure match and the objects, and says so; Auto
  disabled where recognition can't run, and fitting a 320 dp phone's
  dialog.
- `recognition_worker_test.dart`: the worker isolate (with fake models)
  gets a frame's pixels and the analysis options and sends back only the
  analysis; released, it stops and the next frame starts it again; idle,
  it stops by itself; models that fail to load fail the frame and are
  tried again. The Android sampler (a faked channel): sample times, each
  keyframe inside the clip once (across calls too), 3 times per call at
  up to 1280 px, and a JPEG encoded only when asked.
- `persistence_test.dart`: a suggestion and its question survive a refresh,
  can be answered after it, and the answer survives another.
- `test/chrome/` (`flutter test --platform chrome test/chrome/`; the
  models test needs `python3 test/chrome/serve.py` running, and is skipped
  without it):
  - the real models through TensorFlow.js: Grace Hopper pasted on a
    1280 × 720 frame is found (box overlap > 0.6) with her face in the
    upper half, and her face matches her own photo at more than 80 %;
    with faces aligned, Lincoln's two photos score 0.95, Hopper young and
    old 0.91-0.93 (before: 0.88 and 0.63), every Lincoln–Hopper pair
    0.20–0.32 (before: 0.47–0.61); the same frame gets the `human` object
    tag; her picture a third the size (136 × 160 px) at the right of the
    frame is found once, where she is (by a tile). A frame takes about
    1.8 s in this debug build (the detector about 190 ms a run, three
    runs; the Dart pre-processing, slow in debug JavaScript, takes about
    6–10 ms a square once compiled for release);
  - the sampler on a real `MediaRecorder` WebM: a frame every 0.5 s, in
    order, the right colours at the right times, each with a JPEG.
- The same model outputs as TensorFlow Lite in Python (`ai-edge-litert`)
  for the same inputs.
- `integration_test/recognition_android_test.dart`, on an Android 15
  emulator (arm64), with clips made by ffmpeg
  (`integration_test/push_fixtures.sh`):
  - LiteRT gives the same face cosines as TensorFlow.js in Chrome
    (Lincoln–Lincoln 0.88, Lincoln–Hopper 0.61, before faces were aligned);
    a 410 × 480 frame took about 240 ms on the emulator, before
    EfficientDet-Lite2 and its tiles;
  - the sampler reads a red / green / blue MP4 (a keyframe a second)
    asked every 0.5 s: its keyframes at 0, 1 and 2 s, once each, the right
    colour each, each with a JPEG;
  - the recognizer, all real (models in the worker): Grace Hopper tagged
    on her photo, then a new 3 s clip where she appears at 1 s gets a
    recognized "Grace" tag on one of her keyframes (1 or 2 s), on her.

  These were last run before the worker and keyframes (2026-10-05): the
  test and its fixtures are updated (for the new models too), not rerun.
- 714 Flutter tests pass, plus the 6 in Chrome (2026-10-07, with the
  real models). Web release and Android release builds compile (the
  release APK carries LiteRT's libraries for arm64, armv7 and x86_64).
  The worker, keyframes, memory check and the new models are not yet
  tried on a phone.

## Known limitations

- **Accuracy is measured on public datasets, not on this app's footage.**
  COCO, LFW and Market-1501 (see the models' README) stand in for it.
  OSNet was trained on Market-1501's cameras (on other people than those
  it was measured on), so its numbers are likely better than on a home
  camera. Faces under 9 px between the eyes (far from a 720p camera) are
  matched by look, which changes with clothes and light: a subject in
  other clothes than on all their references may only be asked about,
  or missed.
- **Pets** still match by a generic embedder (MobileNetV3): it tells a
  black cat from a white one, not two alike.
- **MobileFaceNet's weights** were trained on MS-Celeb-1M, a research
  dataset since withdrawn: check the license before commercial use, or swap
  in another face embedder (see the models' README).
- **Faces as biometric data:** the recording consent covers faces used to
  identify people "as when naming them in clips"; recognition now does it
  automatically. The consent text and its version may need updating.
- On web the models run on the page's main thread: the app may stutter for
  about 0.2 s at a time (one detector run; the page draws between them)
  while a clip is searched, about 0.7 s of models per frame (around 20 s
  for a 30 s clip). A Web Worker would avoid it.
- **Object tags are COCO's 80 labels only**, from a mobile detector: on
  COCO, at the same score, about 9 in 10 labels it gives are right and it
  finds about two thirds of what's there; very small objects are missed,
  and similar ones mixed up (a cat as a dog). Requiring 2 frames should
  remove more of the wrong ones on real clips, but that isn't measured.
- Object tags make the whole clip be sampled even once every subject is
  found (only the detector, about half a frame's time).
- Clips recorded before object tags (or with them off) get them only from
  Auto, which then searches the whole clip.
- References are rebuilt after each launch (the first clip searched after a
  launch takes longer).
- On a slow phone (DOOGEE S40: 4 × Cortex-A53, 3 GB), a 15 s clip took
  about 64 s, stuttered the app and was followed by a low-memory kill,
  before the worker, keyframes, 640 px and the memory check; how much they
  save there isn't measured yet. The larger detector, its tiles and OSNet
  add about three times the models' work per frame, not yet timed on the
  phone either. The memory margin (threshold + 96 MB) is a guess: on a
  phone always below it, new clips are never searched.
- Sampling keyframes a second apart can miss someone seen for less than
  a second, and a tag's time is its keyframe's, up to half a second from
  when it was asked for.
- iOS doesn't recognize yet.
- A tag made on the **preview** (before the full clip was recorded) keeps
  the preview file's time; once the full clip replaces it, clicking that
  label may open a little off, since the two files start at different
  points.
- LiteRT adds about 7 MB per ABI to the Android app (its GPU library comes
  along, unused), and the models 26 MB (the web app fetches them on first
  use).
- A tag's frame is kept at up to 1280 px (it was 640), so its JPEG, saved
  and synced with the clip, is about three times bigger; it's also a
  better reference.
