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
  `deferred`). Auto is never skipped.
- **Memory (Android):** before a clip's models run, the app asks Android
  how much memory is left (`memoryStatus`, see [Android](android.md)). It's
  **tight** when the system says memory is low, or less than its
  low-memory threshold plus 64 MB is free. Then the models are freed and a
  new clip waits 30 s and asks again, up to 10 times (5 min) before it's
  skipped; Auto doesn't wait but says the phone is low on memory. After
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

1. **References.** For each subject, their latest 10 vouched tags (made or
   confirmed by someone, never recognized ones, so a mistake can't spread).
   On each tag's frame, the person, cat or dog **containing the clicked
   spot** (the smallest such box; else the nearest within 15 % of the
   frame) is the reference. Its embeddings are kept in memory for the
   session, never stored or synced.
2. **Frames.** The clip is sampled **every 1 s**, from its start to its
   end, at most **640 px** wide (reference frames too). On Android each
   sample is the **keyframe** nearest to its time (the recorder makes one
   a second), each once, at its own time, and only those inside the clip:
   a keyframe decodes on its own, where any other frame needs the frames
   since the last keyframe.
3. **Who's there.** On each frame, **EfficientDet-Lite0** scores every
   COCO class on every anchor, once, for both segments:
   - **object tags:** each of the 80 labels scoring **0.5** or more
     somewhere on the frame, with its best score (`person` is `human`);
   - **subjects** (while someone's still to be found):
     EfficientDet's people, cats and dogs (score 0.4 or more;
     overlaps merged), of the sorts some reference is (people if a
     person is known, cats and dogs if a pet is), the **best 3** per
     frame; for each person, **BlazeFace** looks for a face (only if
     some reference has one) in a square around
     them; **MobileFaceNet** embeds it, cropped square at 1.1× its box and
     turned so the eyes are level; everyone gets a **look** embedding
     (**MobileNetV3**) of their box. Once every subject is found, frames
     only go through the detector.
4. **Matching.** Each person or pet is compared with every reference of the
   same sort (people with people, pets with pets): **by face** when both
   show one, **by look** otherwise. The cosine similarity becomes a
   **confidence** from 0 to 1:
   - faces: 0 at 0.30, 1 at 0.80 (so 0.70 is 80 %, 0.55 is 50 %);
   - looks: 0 at 0.45, 1 at 0.90 (0.81 is 80 %).

   Pairs are made surest first, one subject per person and one person per
   subject on a frame.
5. **Tag, ask, or neither** (the threshold in Settings):
   - from **Tag automatically** (default **85 %**): on the **first frame**
     it happens, a **recognized tag** (`source: detected`, with its
     confidence) at the face's center (or the box's), on that frame;
   - below it, always asked: from **30 %** (`RecognitionConfig.askFloor`,
     not a setting) up, a **suggestion**
     (`source: suggested`) on the first frame it happens, and, once the
     clip is done, a **"Is this Rex?"** event (`SubjectSuggestion`). If the
     subject is recognized surely later in the clip, they're tagged instead
     and nothing is asked;
   - under 30 %: nothing. A face at 30 % has a cosine of 0.45, where
     different people mostly score, so lower matches would mostly ask
     about strangers. (There used to be an **Ask me** slider, default
     50 %; it's gone, and stored `ask` values are ignored.)

   A subject is tagged or asked about at most once per clip; later frames
   don't add more. Subjects already on the clip are skipped, and the
   subjects' segment stops once every subject is found.
6. **Object tags:** each label is kept **once per clip**, from the **first
   frame** it scores on (`ms` into the recording) with that frame's score;
   later frames don't add it again. The whole clip is sampled for them,
   then stored together, in order of first sighting.

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
  pre-processing (bilinear sampling, crops, rotation), EfficientDet's
  anchors, box decoding and labels (`cocoLabels`, `decodeObjects`;
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
  `WorkerVision`) owns the four models: it loads them (mapped from files
  the assets are copied to, so nothing is held twice and nothing leaks
  when they're freed), builds the anchors, resizes each frame to each
  model's input, runs them and decodes their outputs, reading
  EfficientDet's 7 MB of scores in place. The app's isolate only sends
  each frame's RGBA pixels (moved, not copied) and gets back who's on it,
  so it doesn't stall. Frames come from `keyframesAt` on the
  `presence/cameras` channel, 3 times per call, as raw RGBA; a frame's
  JPEG is only made (`encodeJpeg`) when a tag or suggestion keeps it.
  Reference frames (JPEGs) are still decoded by the engine
  (`instantiateImageCodec`). See [Android](android.md).
- **iOS:** not yet (the switch says "Not available on this device yet").
  `tflite_flutter` supports iOS, so it needs `keyframesAt` and
  `encodeJpeg` in Swift; the iOS app already links its `TensorFlowLiteC`
  2.12 through CocoaPods.
- **Models** (`assets/models/`, 14 MB; on web fetched only when
  recognition first runs, in the Android app bundled): see [assets/models/README.md](../presence_app/assets/models/README.md)
  for sources, checksums and licenses.

## Verified

- `recognition_test.dart`: EfficientDet and BlazeFace decoding; object
  labels (80, `human` for people, best score once, unsure and unused
  classes left out); pixel
  scales, rotation and black outside the picture; confidence scales; faces
  compared when both show, looks otherwise, people never matched to pets;
  one subject per person, surest first; a tag picks the smallest detection
  around it; settings limits and round-trip; tag sources and confidences
  round-trip, suggestions not tags nor subjects; the suggestion event
  round-trip; the recognizer (fake models) tags a sure match on its first
  frame, asks about an unsure one on its first frame (one JPEG per frame
  used), stops once everyone's found, skips who's tagged, never learns from
  recognized tags, and does nothing when off; the card's Yes and No; on
  request it runs even when off and reports who it tagged and asked
  about, then that everyone is on the clip; a new clip published while
  recording isn't searched until its full recording is done, Auto on
  another clip runs meanwhile, and its subject is tagged once, on the
  first frame they're on; a new clip searched with Auto isn't searched
  again; nobody to look for (none
  tagged, or the tag points at nobody) and nobody found; a failed model
  load doesn't block the next run; only the sorts of subject known are
  embedded, at most 3 detections a frame (`keepDetections`); only the
  latest 3 new clips wait (older ones skipped, Auto never); tight memory
  puts Auto off and frees the models, and makes a new clip wait until
  there's room or give up after its retries; what counts as tight; object
  tags: each label once, from its
  first frame, over the whole clip, with nobody to look for, and not again
  once searched; they keep going after every subject is found (subjects
  only embedded until then); off in Settings, none stored; their record
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
  640 px, and a JPEG encoded only when asked.
- `persistence_test.dart`: a suggestion and its question survive a refresh,
  can be answered after it, and the answer survives another.
- `test/chrome/` (`flutter test --platform chrome test/chrome/`; the
  models test needs `python3 test/chrome/serve.py` running, and is skipped
  without it):
  - the real models through TensorFlow.js: Grace Hopper pasted on a
    1280 × 720 frame is found (box overlap > 0.6) with her face in the
    upper half, and her face matches her own photo at more than 80 %;
    Lincoln's two photos score 0.88, above every Lincoln–Hopper pair
    (0.47–0.61); Hopper young and old score 0.63 (an "ask"); the same frame
    gets the `human` object tag. A frame takes about 170–210 ms (debug
    build);
  - the sampler on a real `MediaRecorder` WebM: a frame every 0.5 s, in
    order, the right colours at the right times, each with a JPEG.
- The same model outputs as TensorFlow Lite in Python (`ai-edge-litert`)
  for the same inputs.
- `integration_test/recognition_android_test.dart`, on an Android 15
  emulator (arm64), with clips made by ffmpeg
  (`integration_test/push_fixtures.sh`):
  - LiteRT gives the same face cosines as TensorFlow.js in Chrome
    (Lincoln–Lincoln 0.88, Lincoln–Hopper 0.61); a 410 × 480 frame takes
    about 240 ms on the emulator;
  - the sampler reads a red / green / blue MP4 (a keyframe a second)
    asked every 0.5 s: its keyframes at 0, 1 and 2 s, once each, the right
    colour each, each with a JPEG;
  - the recognizer, all real (models in the worker): Grace Hopper tagged
    on her photo, then a new 3 s clip where she appears at 1 s gets a
    recognized "Grace" tag on the 1 s keyframe, on her.

  These were last run before the worker and keyframes (2026-10-05): the
  test and its fixtures are updated, not rerun.
- 401 Flutter tests pass, plus the 3 in Chrome (not rerun since object
  tags). Web release and Android debug builds compile (the release APK
  carries LiteRT's libraries for arm64, armv7 and x86_64).
  The worker, keyframes and memory check are not yet tried on a phone.

## Known limitations

- **Accuracy is untested on real camera footage.** The thresholds come from
  portrait photos; faces far from the camera are small and may not be
  found (BlazeFace short range is meant for faces within about 2 m), so
  people then match by look, which changes with clothes and light.
- **MobileFaceNet's weights** were trained on MS-Celeb-1M, a research
  dataset since withdrawn: check the license before commercial use, or swap
  in another face embedder (see the models' README).
- **Faces as biometric data:** the recording consent covers faces used to
  identify people "as when naming them in clips"; recognition now does it
  automatically. The consent text and its version may need updating.
- On web the models run on the page's main thread: the app may stutter for
  about 0.2 s per frame while a clip is searched (around 10 s for a 30 s
  clip). A Web Worker would avoid it.
- **Object tags are COCO's 80 labels only**, at 0.5 from a small detector
  run at 320 px: small or far objects are missed, and similar ones mixed
  up (a cat as a dog). No real-footage accuracy check yet, and other
  labels than `human` haven't been checked on real pictures.
- Object tags make the whole clip be sampled even once every subject is
  found (only the detector, about a third of a frame's time).
- Clips recorded before object tags (or with them off) get them only from
  Auto, which then searches the whole clip.
- References are rebuilt after each launch (the first clip searched after a
  launch takes longer).
- On a slow phone (DOOGEE S40: 4 × Cortex-A53, 3 GB), a 15 s clip took
  about 64 s, stuttered the app and was followed by a low-memory kill,
  before the worker, keyframes, 640 px and the memory check; how much they
  save there isn't measured yet. The memory margin (threshold + 64 MB) is
  a guess: on a phone always below it, new clips are never searched.
- Sampling keyframes a second apart can miss someone seen for less than
  a second, and a tag's time is its keyframe's, up to half a second from
  when it was asked for.
- iOS doesn't recognize yet.
- A tag made on the **preview** (before the full clip was recorded) keeps
  the preview file's time; once the full clip replaces it, clicking that
  label may open a little off, since the two files start at different
  points.
- LiteRT adds about 7 MB per ABI to the Android app (its GPU library comes
  along, unused), and the models 14 MB.
