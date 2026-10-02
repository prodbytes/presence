# Recognition models

The TensorFlow Lite models subject recognition runs
([lib/recognition/vision.dart](../../lib/recognition/vision.dart)), the
same files on every platform. Replace one by dropping in a file with the
same name, input and output shapes.

| File | What it does | Input → output | Source | License |
|---|---|---|---|---|
| `efficientdet_lite0.tflite` | People, cats and dogs on a frame (COCO, int8) | 320×320×3 uint8 → 19206 anchors × (90 scores, 4 box offsets) | [MediaPipe object detector](https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/int8/latest/efficientdet_lite0.tflite) | Apache-2.0 |
| `blaze_face_short_range.tflite` | A face on a person | 128×128×3 float (−1…1) → 896 anchors × (16 regressors, 1 logit) | [MediaPipe face detector](https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/latest/blaze_face_short_range.tflite) | Apache-2.0 |
| `mobilefacenet.tflite` | A face's embedding | 112×112×3 float ((v−127.5)/128) → 192 | [MobileFaceNet](https://github.com/sirius-ai/MobileFaceNet_TF) (Apache-2.0 code), file from [FaceRecognitionAuth](https://raw.githubusercontent.com/MCarlomagno/FaceRecognitionAuth/master/assets/mobilefacenet.tflite) (BSD-3-Clause) | see note |
| `mobilenet_v3_small.tflite` | A person's or pet's look | 224×224×3 float (0…1) → 1024 | [MediaPipe image embedder](https://storage.googleapis.com/mediapipe-models/image_embedder/mobilenet_v3_small/float32/latest/mobilenet_v3_small.tflite) | Apache-2.0 |

SHA-256:

```
0720bf247bd76e6594ea28fa9c6f7c5242be774818997dbbeffc4da460c723bb  efficientdet_lite0.tflite
b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f  blaze_face_short_range.tflite
be4bc7cfc53f7bc336d0f28b1ab92535f618c913a422b683210750f6b5354854  mobilefacenet.tflite
bbbb4c51a55a53905af1daec995ca1aae355046f8839bb8c9f5ce9271394bc40  mobilenet_v3_small.tflite
```

**Note on MobileFaceNet:** the code is Apache-2.0, but these weights were
trained on MS-Celeb-1M, a dataset released for research and since
withdrawn. Check the license before commercial use, or swap in a face
embedder trained on data cleared for it (same 112×112 input; any
embedding length works).
