# Subject recognition

Every new clip is searched for the [subjects](subjects.md) tagged before:
the people and pets someone named on earlier clips. Whoever is recognized
surely is tagged on the clip; whoever only might be is asked about
([lib/recognition/](../presence_app/lib/recognition)).

## When it runs

- On each **new clip** (pressed, motion, scheduled or startup), once its
  **full recording** is saved. Clips run one at a time, in the background,
  on the device that recorded them. Restored and synced clips aren't run.
- Only with **Recognize subjects in new clips** on (Settings, default on)
  and on a platform that has the runtime: **web** and **Android**. iOS
  comes next, with the same models (see [Platforms](platforms.md)).
- Only when some subject has a **reference**: a tag someone made, or a
  suggestion someone confirmed, with its frame.

## How

1. **References.** For each subject, their latest 10 vouched tags (made or
   confirmed by someone, never recognized ones, so a mistake can't spread).
   On each tag's frame, the person, cat or dog **containing the clicked
   spot** (the smallest such box; else the nearest within 15 % of the
   frame) is the reference. Its embeddings are kept in memory for the
   session, never stored or synced.
2. **Frames.** The clip is sampled **every 0.5 s**, from its start to its
   end, at most 960 px wide.
3. **Who's there.** On each frame:
   - **EfficientDet-Lite0** finds people, cats and dogs (score 0.4 or more;
     overlaps merged);
   - for each person, **BlazeFace** looks for a face in a square around
     them; **MobileFaceNet** embeds it, cropped square at 1.1× its box and
     turned so the eyes are level;
   - everyone gets a **look** embedding (**MobileNetV3**) of their box.
4. **Matching.** Each person or pet is compared with every reference of the
   same sort (people with people, pets with pets): **by face** when both
   show one, **by look** otherwise. The cosine similarity becomes a
   **confidence** from 0 to 1:
   - faces: 0 at 0.30, 1 at 0.80 (so 0.70 is 80 %, 0.55 is 50 %);
   - looks: 0 at 0.45, 1 at 0.90 (0.81 is 80 %).

   Pairs are made surest first, one subject per person and one person per
   subject on a frame.
5. **Tag, ask, or neither** (thresholds in Settings):
   - from **Tag automatically** (default **80 %**): on the **first frame**
     it happens, a **recognized tag** (`source: detected`, with its
     confidence) at the face's center (or the box's), on that frame;
   - from **Ask me** (default **50 %**) but below: a **suggestion**
     (`source: suggested`) on the first frame it happens, and, once the
     clip is done, a **"Is this Rex?"** event (`SubjectSuggestion`). If the
     subject is recognized surely later in the clip, they're tagged instead
     and nothing is asked;
   - below: nothing.

   A subject is tagged or asked about at most once per clip; later frames
   don't add more. Subjects already on the clip are skipped, and sampling
   stops once every subject is found.

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
  anchors and box decoding, BlazeFace's anchors, non-maximum suppression,
  matching and thresholds. Each platform only runs the models and reads
  frames, so all give the same results.
- **Web:** **TensorFlow.js** with `@tensorflow/tfjs-tflite` (TensorFlow
  Lite in WebAssembly, SIMD), served from `/app/tfjs/` with the app and
  loaded on first use (see [web/tfjs/README.md](../presence_app/web/tfjs/README.md));
  frames from a hidden, muted `<video>` seeked through the recording and
  drawn on a canvas.
- **Android:** **LiteRT** (TensorFlow Lite, `com.google.ai.edge.litert`
  1.4.0) through Google's **`tflite_flutter`** plugin (0.12.1, Dart FFI),
  4 CPU threads; each model runs in its own background isolate
  (`IsolateInterpreter`), so the app doesn't stall. Frames come from the
  `framesAt` method of the `presence/cameras` channel:
  `MediaMetadataRetriever` opens the MP4 once per batch of 8 times and
  returns each frame upright, at most 960 px wide, as a JPEG (null for one
  it can't read), which Dart decodes. See [Android](android.md).
- **iOS:** not yet (the switch says "Not available on this device yet").
  `tflite_flutter` supports iOS, so it needs only `framesAt` in Swift.
- **Models** (`assets/models/`, 14 MB; on web fetched only when
  recognition first runs, in the Android app bundled): see [assets/models/README.md](../presence_app/assets/models/README.md)
  for sources, checksums and licenses.

## Verified

- `recognition_test.dart`: EfficientDet and BlazeFace decoding; pixel
  scales, rotation and black outside the picture; confidence scales; faces
  compared when both show, looks otherwise, people never matched to pets;
  one subject per person, surest first; a tag picks the smallest detection
  around it; settings limits and round-trip; tag sources and confidences
  round-trip, suggestions not tags nor subjects; the suggestion event
  round-trip; the recognizer (fake models) tags a sure match on its first
  frame, asks about an unsure one on its first frame (one JPEG per frame
  used), stops once everyone's found, skips who's tagged, never learns from
  recognized tags, and does nothing when off; the card's Yes and No.
- `persistence_test.dart`: a suggestion and its question survive a refresh,
  can be answered after it, and the answer survives another.
- `test/chrome/` (`flutter test --platform chrome test/chrome/`; the
  models test needs `python3 test/chrome/serve.py` running, and is skipped
  without it):
  - the real models through TensorFlow.js: Grace Hopper pasted on a
    1280 × 720 frame is found (box overlap > 0.6) with her face in the
    upper half, and her face matches her own photo at more than 80 %;
    Lincoln's two photos score 0.88, above every Lincoln–Hopper pair
    (0.47–0.61); Hopper young and old score 0.63 (an "ask"). A frame takes
    about 170 ms (debug build);
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
  - `framesAt` reads a red / green / blue MP4 at 0, 0.5, … 2.5 s, the right
    colour each time, each with a JPEG;
  - the recognizer, all real: Grace Hopper tagged on her photo, then a new
    3 s clip where she appears at 1 s gets a recognized "Grace" tag (100 %)
    on the 1.0 s frame, on her, and stops there (0.9 s in all).
- 233 Flutter tests pass, plus the 3 in Chrome and the 3 on Android. Web
  release, Android debug and release builds compile (the release APK
  carries LiteRT's libraries for arm64, armv7 and x86_64).
  Not yet tried end to end in the app with a camera, nor on a phone.

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
- References are rebuilt after each launch (the first clip searched after a
  launch takes longer).
- iOS doesn't recognize yet.
- LiteRT adds about 7 MB per ABI to the Android app (its GPU library comes
  along, unused), and the models 14 MB.
