# Cloud recognition

**Premium profiles** also have their subjects recognized in the cloud, by
**DINOv2-L** (ViT-L/14), which told one black cat from other black cats far
better than the app's on-device models. Two Lambda APIs in the auth API's
stack do it: **training**, which learns the profile's subjects from the
labels people place, and **inference**, which says who a new clip's people
and pets may be. The app places the labels, as with its own recognition
([Subject recognition](recognition.md)).

## Why DINOv2-L (2026-10-11)

Measured on one black cat, Suerte (45 images from 7 places: video stills
and photos), against 36 other cats (18 black), with the crops of each cat
found by a detector:

- **Matching a crop against her other images** (what the app does on the
  device), in a place she was never seen there: every model was near
  chance. DINOv2-L was best (AUC 0.75 against the black cats; MobileNetV3,
  the app's pet model, 0.63; MegaDescriptor-L 0.64; CLIP, SigLIP2,
  MiewID lower). In the same place, another session: DINOv2-L 0.94,
  MobileNetV3 0.89.
- **A classifier learned per subject**, against unknown people and pets
  (below), in places she was never labeled: **AUC 0.91** against the black
  cats; 53 % of her crops at 90 % or more, 6 % of the black cats.
- **As run in Lambda**: ONNX (`onnx-community/dinov2-large`, fp32), 224 px:
  as good as PyTorch at 518 px (0.78 vs 0.75 matching), ~180 ms a crop on 2
  CPU threads. The int8 export was worse (0.71), and 336 px worse still.
  Java's embeddings equal Python's (cosine 1.000), and its classifier the
  prototype's (AUC 0.906).
- Few images, from one home: a direction, not a verdict. Amazon
  Rekognition's labels only say "Black Cat" (no individuals); Custom
  Labels and Bedrock's image embeddings weren't tried (not allowed in the
  account).

## The labels and the check

- **A label** is a tag someone placed ([TagSource.vouched]: tagged by
  hand, or a suggestion confirmed), with its frame. Each now records
  **`labeledAt`** (ms since the epoch) when it's placed, confirmed or
  renamed (`Annotation.clock`); recognition's own tags have none. Older
  tags without it count from their ID's time (`labeledTime`).
- **The training check** (`CloudTrainer`,
  [cloud_recognition.dart](../presence_app/lib/recognition/cloud_recognition.dart)),
  on a premium profile only:
  - **when it runs**: at once when the app starts (or signs in) premium
    (the roles answering), then every **24 h** since the last check
    (`cloudCheckedAt`, looked at every 15 min). A failed check is tried
    again after **15 min**. One at a time.
  - **what it decides**: it asks the API's status (when it last trained,
    the labels it holds), and trains if:
    - it was never trained and there are **3** labels or more;
    - **5** labels or more are new since the last training (`labeledAt`
      after it); or
    - **7 days** have passed since the last training.
  - **training**: the crops of the labels the API doesn't hold yet (newest
    first, **8** per request), then the profile's labels. The time it
    trained is kept in the settings (`recognition.cloudTrainedAt`, synced
    with the device's settings) and shown in Settings.
- **A label's crop** (`SubjectRecognizer.cloudCrop`): its frame opened,
  the person or pet it points at found as for the device's references
  (the smallest detection containing the spot, else the nearest), and a
  square around them, black outside the frame, shrunk to **224 × 224**
  RGB (`CloudCrop`). People are `person`, cats and dogs `pet`. It waits
  its turn with the clips being searched (one user of the models), and is
  skipped while memory is tight. A label whose frame can't be opened yet,
  or that points at nobody, is left out until a later check.
- **Removals**: the train request lists the clips this device has; the API
  forgets its labels on those clips that are no longer there (removed),
  and keeps labels on other clips (beyond this device's history). Renamed
  labels are renamed.
- **Settings**: under the Recognition section, for a premium profile, a
  **Cloud recognition (Premium)** line (`CloudRecognitionTile`): "Last
  trained 11 Oct 14:02" or "Not trained yet", "Learns from the people and
  pets you tag; checked daily", and a **Train now** button, which trains
  whatever there is (any label) and says how it went.

## Inference

- **On each clip** the device searches for subjects, when the profile is
  premium and its model trained (`CloudIdentifier`): the people and pets
  seen are cropped as above, at most **2 a frame** (the surest
  detections) and **8 a clip**, each with the frame's JPEG (a tag frame),
  and sent in one request after the clip is sampled.
- **The answer**: each crop's likeliest subjects of its sort (up to 3,
  from 5 %). Each subject's cloud confidence is pooled as on the device
  (the mean of their best 3 crops). **Each subject's confidence is the
  higher of the device's and the cloud's**, and the tag goes where the
  surer one saw them: tagged from the auto-tag level (90 %), asked about
  ("Is this Rex?") from 50 %, as before. A subject only the cloud knows is
  tagged too. Subjects already on the clip are skipped.
- A failed request (offline, a cold start past 30 s) leaves the device's
  own verdict; it's logged.

## The APIs

In [presence_api_auth](../presence_api_auth) (`RecognitionFunction`, its
own jar), under `/api/recognition/*` behind the same Google JWT
authorizer, CloudFront `/api/*` origin and throttles. Every route needs a
verified email and a **premium** profile (`presence_premium`, as the
caller's or the profile owner's; [Premium](premium.md)): 403 otherwise.

| Route | Function | Body | Answer |
|---|---|---|---|
| `GET /api/recognition/status` | `RecognitionTrainFunction` | | `{"model": "dinov2-large", "trainedAt" (null if never), "labels": [{id, labeledAt}], "subjects": [{name, kind, labels}]}` |
| `POST /api/recognition/labels` | `RecognitionTrainFunction` | `{"labels": [{id, clipId, name, kind, labeledAt, pixels}]}`, 1–8 | `{"stored", "labels"}`; 413 past 2000 labels |
| `POST /api/recognition/train` | `RecognitionTrainFunction` | `{"labels": [{id, name}], "clips": [id]}` | `{"trainedAt", "labels", "subjects"}` |
| `POST /api/recognition/identify` | `RecognitionInferFunction` | `{"crops": [{id, kind, pixels}]}`, 1–8 | `{"trainedAt", "results": [{id, labels: [{name, confidence}]}]}` |

- `kind`: `person`, or `pet` (`cat` and `dog` are read as `pet`).
  `pixels`: 224 × 224 RGB bytes, row by row, in base64 (150,528 bytes).
  A bad body is 400.
- **Only embeddings are kept, never crops**: `RecognitionTable`, per
  profile, `label#<id>` items (`clipId`, `name`, `kind`, `labeledAt`,
  `vector`: 1024 float32s) and a `model` item (`trainedAt`, `labels`,
  `subjects`: `{name, kind, labels, bias, weights}`). A crop is seen
  only in the function's memory, over HTTPS. The app's media stays
  sealed in the bucket ([Media encryption](encryption.md)): the crops
  come from the device, which can open them.
- **Without a model** (never trained, or no subjects) identify answers
  `trainedAt` (or null) and no results, without loading DINOv2.

### The model in Lambda

- `Dinov2` ([Dinov2.java](../presence_api_auth/RecognitionFunction/src/main/java/presence/auth/Dinov2.java)):
  ONNX Runtime 1.30 (Java, CPU, all threads). A crop normalized with
  ImageNet's mean and deviation; the embedding is the last layer's class
  token, made unit length.
- **The file** (1.2 GB, too big for a package; `ModelFile`): fetched at an
  instance's first use into `/tmp` (3 GB of ephemeral storage), from the
  user-data bucket's `models/dinov2-large-305351060a1939d9.onnx` (a prefix
  only the functions reach), or else from Hugging Face at the pinned
  revision `4b3550c5…` and then kept in the bucket. Its SHA-256 must be
  `30535106…7d6ac`, or it isn't used. The bucket's lifecycle expires it
  after 90 days; the next instance fetches it again.
- **Functions**: Java 25, 3008 MB, 120 s timeout (the API gives up at
  30 s; a first fetch finishes anyway, and the next request finds the
  model), packaged by the [Makefile](../presence_api_auth/Makefile)
  (SAM's makefile build): `RecognitionFunction`'s
  [pom.xml](../presence_api_auth/RecognitionFunction/pom.xml) compiles the
  auth API's sources with its own (the caller, profiles, roles), adds ONNX
  Runtime with only its Linux libraries (47 MB jar) and jackson-jr.
- **Throttles**: labels 2/s (burst 10), train 1/s (burst 5), identify 5/s
  (burst 20).

### The classifier

`Classifier`, one logistic regression per subject (one against the rest),
retrained in full at each training (about 0.15 s a subject):

- **positives**: the subject's labels (named as on its latest);
- **negatives**: the profile's other subjects of the same sort, and
  **unknown people and pets**: 400 people, 188 cats and 176 dogs from COCO
  val2017, embedded the same way (`negatives.bin`, float16, 1.5 MB), so a
  profile with one subject still learns what isn't them;
- class-balanced, L2 0.3, on embeddings scaled to length 32, 300 steps of
  gradient descent with Nesterov momentum (0.9, rate 0.5). Weaker
  regularization ranked as well but was surer of strangers (L2 0.01: 28 %
  of the black cats over 90 %);
- up to 50 subjects (the most labeled); a profile keeps up to 2000 labels.

## Licenses

DINOv2 (`facebook/dinov2-large`) and its ONNX export are Apache-2.0. The
negatives are embeddings (not images) of COCO val2017 crops: COCO's
annotations are CC BY 4.0, its images under their Flickr licenses.

## Local

The local stack (Floci) deploys both functions and creates the four routes
(`presence_floci/init/ready.d/05-auth-api.sh`, RBAC mode only). There's no
bucket to keep the model in, so each function fetches it from Hugging Face
at its first use (1.2 GB).

## Verified

- `RecognitionTest` (JUnit, fake embedder and store): premium only, a
  verified email; without a model, nothing is embedded; bad labels refused
  (9 at once, wrong pixels, an unknown kind, no body); labels stored,
  trained, renamed ("Suerte" and " suerte " one subject), a removed one
  forgotten, and identify names the subject (over 90 %), not another
  colour (under 50 %), and no person when none is known; labels on clips
  the device doesn't have are kept; the negatives load (400, 364), unit
  length.
- `Dinov2Test`: the real model when `PRESENCE_TEST_MODEL` names it (run
  locally): 1024 values, unit length, stripes nearer stripes than noise;
  a file with the wrong SHA-256 is deleted.
- Java against the Python prototype (once, not a test): the same
  embedding (cosine 1.000) and AUC (0.906).
- `cloud_recognition_test.dart`: labels timed when placed, confirmed or
  renamed, not recognition's; the JSON round-trip; an older tag's time
  from its ID; the settings' round-trip; the check: not premium, 3 for a
  first training, 5 new (sending only the new crops), 7 days with nothing
  new, every 24 h unless forced, a failure retried after 15 min, 8 crops
  a request and labels without a crop left out, Train now, becoming
  premium checks at once; the HTTP client's requests and answers; the
  Settings line before and after Train now.
- `recognition_test.dart`: the cloud surer than the device tags where it
  saw them (a person, 224 × 224 × 3 bytes); someone only the cloud knows,
  unsure, is asked about; 8 crops at most, 2 a frame; not asked when
  unavailable; a label's crop is its detection's, its sort `pet`, and
  null where nobody is.
- `sam build` packages both functions (47 MB each).
- **In the Lambda Java 25 runtime** (`public.ecr.aws/lambda/java:25`,
  arm64, 3008 MB, with DynamoDB Local and RC rbacr), driven with API
  Gateway events: a free account 403; a premium one's status, 39 of
  Suerte's labels from 6 places (8 a request, 2–4.5 s each), training
  (0.2 s), then her photos from the 7th place and 18 other black cats
  identified: **AUC 0.95**, her 6 crops 0.83–0.95, 1 of 18 black cats at
  90 % or more (12 at 50 % or more: asked about). Identify: 12 s cold
  (loading the model), 3 s warm for 8 crops. A cold start without the
  model fetched it from Hugging Face, checked it and answered in 57 s.

## Known limitations

- **Not yet run in AWS** at the time of writing (only in the Lambda
  runtime's image): the account's memory limit (3008 MB), the bucket's
  copy of the model, and how long an instance takes to read it from the
  bucket.
- **The first request** of an instance waits for the model (seconds from
  the bucket, longer from Hugging Face): a clip searched then may get the
  device's verdict only, and a training check fails and retries in 15 min.
- **Crops are seen by the server** (in memory, not kept), unlike the
  sealed media; the embeddings are kept in DynamoDB, unencrypted beyond
  the table's own encryption.
- **Each premium device checks** on its own; two may train the same day.
- **COCO's negatives** have few black cats: a black cat nobody tagged is
  more often taken for a known black cat than a tabby is.
- A label removed on a clip that's past this device's history is forgotten
  only by a device that still has the clip.
