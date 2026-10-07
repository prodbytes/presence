# Recognition models

The TensorFlow Lite models subject recognition runs
([lib/recognition/vision.dart](../../lib/recognition/vision.dart)), the
same files on every platform. Replace one by dropping in a file with the
same name, input and output shapes.

| File | What it does | Input → output | Source | License |
|---|---|---|---|---|
| `efficientdet_lite2.tflite` | People, cats and dogs on a frame, and the object tags (COCO, int8) | 448×448×3 uint8 → 37629 anchors × (90 scores, 4 box offsets) | [MediaPipe object detector](https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite2/int8/latest/efficientdet_lite2.tflite) | Apache-2.0 |
| `blaze_face_short_range.tflite` | A face on a person | 128×128×3 float (−1…1) → 896 anchors × (16 regressors, 1 logit) | [MediaPipe face detector](https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/latest/blaze_face_short_range.tflite) | Apache-2.0 |
| `mobilefacenet.tflite` | A face's embedding | 112×112×3 float ((v−127.5)/128), aligned → 192 | [MobileFaceNet](https://github.com/sirius-ai/MobileFaceNet_TF) (Apache-2.0 code), file from [FaceRecognitionAuth](https://raw.githubusercontent.com/MCarlomagno/FaceRecognitionAuth/master/assets/mobilefacenet.tflite) (BSD-3-Clause) | see note |
| `osnet.tflite` | A person's look (re-identification) | 256×128×3 float (0…1; normalized inside) → 512 | [Qualcomm AI Hub OSNet](https://huggingface.co/qualcomm/OSNet) v0.63.0 `osnet-tflite-float`, from [torchreid](https://github.com/KaiyangZhou/deep-person-reid) | MIT, see note |
| `mobilenet_v3_small.tflite` | A pet's look | 224×224×3 float (0…1) → 1024 | [MediaPipe image embedder](https://storage.googleapis.com/mediapipe-models/image_embedder/mobilenet_v3_small/float32/latest/mobilenet_v3_small.tflite) | Apache-2.0 |

SHA-256:

```
b3f50554cb0ea559e90328845f7d9ba4d13c8bff372914d24e06bc8bb72fa896  efficientdet_lite2.tflite
b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f  blaze_face_short_range.tflite
be4bc7cfc53f7bc336d0f28b1ab92535f618c913a422b683210750f6b5354854  mobilefacenet.tflite
42d2b1d91ae578f26f944fef81682045b571727e6bd17967917d56f824b6b5ea  osnet.tflite
bbbb4c51a55a53905af1daec995ca1aae355046f8839bb8c9f5ce9271394bc40  mobilenet_v3_small.tflite
```

**Note on MobileFaceNet:** the code is Apache-2.0, but these weights were
trained on MS-Celeb-1M, a dataset released for research and since
withdrawn. Check the license before commercial use, or swap in a face
embedder trained on data cleared for it (same 112×112 aligned input; any
embedding length works).

**Note on OSNet:** the code and export are MIT, but the checkpoint
(`osnet_x1_0_market_256x128…`) was trained on Market-1501, a research
dataset. The same check applies.

## How they were chosen (2026-10-06)

Measured with the same models in Python (`ai-edge-litert`), with the same
pre-processing as the app, on public datasets (not bundled):

- **Detector anchors.** The model file lists its anchors in its metadata:
  each level's grid is the input over 2^level rounded up, anchors centered
  on its cells and 3 cells across. The app's earlier anchors were 4
  strides across, centered by stride, which made boxes about a third too
  big and put the largest ones off-center. Fixed, on 500 COCO val2017
  images at score 0.4: box precision for people 0.73 → 0.88, medium people
  found 134 → 186 of 350.
- **Detector.** EfficientDet-Lite2 (448 px) over Lite0 (320 px): object
  tags' recall 0.56 → 0.64 at the same precision (0.89); people found
  small 32 → 67 of 434, medium 186 → 241 of 350. The frame is squared
  (black around it) instead of stretched. Adding overlapping square tiles
  along a wide frame, merged (overlap over 0.5, or 80 % inside a better
  box): small 67 → 135, medium 241 → 245, at precision 0.83. About three
  times the detector's time.
- **Faces.** On COCO's people whose eyes and nose show (336): looking for
  the face in a square around the head first, then around the whole
  person (kept only in their top 35 %), found 295 against 241 for the
  whole-person square alone, with 12 in the wrong place against 36.
  BlazeFace full range found no more. **Alignment:** a face cropped from
  BlazeFace's box made LFW's pairs 76 % right; aligned to ArcFace's
  template (eyes, nose, mouth), 98.7 %. Different people then score under
  0.44 (99.9 %), the same person 0.62–0.75 typically, down to faces 10 px
  between the eyes; at 7 px it no longer works, hence the 9 px minimum.
  Averaging with the mirror image adds a point or two.
- **Looks.** On Market-1501 (150 people asked, 5285 pictures searched):
  MobileNetV3 small found the right person first 16 % of the time (20 %
  with a square crop; large, 22 %; DINOv2 ViT-S/14's mean patch token,
  25 %); OSNet, 95 % (on people it wasn't trained on, but in that
  dataset's cameras). With half the people known and the others strangers,
  pooling a clip's best 3 frames tagged 93 % right with 8 % of strangers
  taken for someone (out of 75 known: fewer known, fewer mistakes).
  MobileNetV3 small stays for pets (no pet re-identification model is
  bundled).
