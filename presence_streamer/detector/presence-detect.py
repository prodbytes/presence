#!/usr/bin/python3
"""presence-detect: finds people and animals on a chunk's frames.

presence-streamer runs it once and keeps it running. It reads one request
per line on stdin and answers one JSON line on stdout:

  {"frames": [{"path": "/…/f0001.jpg", "ms": 0}, …], "thumbnail": "/…/t.jpg"}
  -> {"objects": [{"label": "human", "ms": 4000, "score": 0.91}, …],
      "subject": {"label": "human", "ms": 4000, "score": 0.91} or null}

Each object is a label's best score over the frames (at least --min-score)
and the time of that frame. The subject is the best person or animal
(--subject-score or more); its frame is written to "thumbnail" (JPEG, at
most 640 px wide). The labels are the app's (COCO's 80, people as `human`).

It uses YOLOv4-tiny (COCO) through OpenCV's DNN module, which Debian and
Raspberry Pi OS package for 32- and 64-bit ARM (python3-opencv).
"""

import argparse
import json
import sys

import cv2
import numpy as np

# COCO's 80 classes in the model's order, named as the app names them
# (presence_app/lib/recognition/vision.dart, cocoLabels).
LABELS = [
    "human", "bicycle", "car", "motorcycle", "airplane", "bus", "train",
    "truck", "boat", "traffic light", "fire hydrant", "stop sign",
    "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
    "elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag",
    "tie", "suitcase", "frisbee", "skis", "snowboard", "sports ball", "kite",
    "baseball bat", "baseball glove", "skateboard", "surfboard",
    "tennis racket", "bottle", "wine glass", "cup", "fork", "knife", "spoon",
    "bowl", "banana", "apple", "sandwich", "orange", "broccoli", "carrot",
    "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant",
    "bed", "dining table", "toilet", "tv", "laptop", "mouse", "remote",
    "keyboard", "cell phone", "microwave", "oven", "toaster", "sink",
    "refrigerator", "book", "clock", "vase", "scissors", "teddy bear",
    "hair drier", "toothbrush",
]

# People and animals: what makes a chunk worth keeping.
SUBJECTS = {
    "human", "bird", "cat", "dog", "horse", "sheep", "cow", "elephant",
    "bear", "zebra", "giraffe",
}


def search(model, request, min_score, subject_score):
    best = {}  # label -> (score, ms)
    subject = None  # (score, label, ms, frame)
    for f in request.get("frames", []):
        frame = cv2.imread(f["path"])
        if frame is None:
            continue
        classes, scores, _ = model.detect(frame, confThreshold=min_score, nmsThreshold=0.4)
        for c, s in zip(np.array(classes).flatten(), np.array(scores).flatten()):
            c, s = int(c), float(s)
            if c < 0 or c >= len(LABELS):
                continue
            label = LABELS[c]
            if label not in best or s > best[label][0]:
                best[label] = (s, f["ms"])
            if label in SUBJECTS and s >= subject_score and (subject is None or s > subject[0]):
                subject = (s, label, f["ms"], frame)
    answer = {
        "objects": [
            {"label": label, "ms": int(ms), "score": round(score, 3)}
            for label, (score, ms) in sorted(best.items())
        ],
        "subject": None,
    }
    if subject is not None:
        score, label, ms, frame = subject
        answer["subject"] = {"label": label, "ms": int(ms), "score": round(score, 3)}
        thumbnail = request.get("thumbnail")
        if thumbnail:
            h, w = frame.shape[:2]
            if w > 640:
                frame = cv2.resize(frame, (640, round(h * 640 / w)), interpolation=cv2.INTER_AREA)
            cv2.imwrite(thumbnail, frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
    return answer


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--cfg", required=True)
    p.add_argument("--weights", required=True)
    p.add_argument("--size", type=int, default=416)
    p.add_argument("--min-score", type=float, default=0.4)
    p.add_argument("--subject-score", type=float, default=0.5)
    p.add_argument("--threads", type=int, default=0)
    args = p.parse_args()

    if args.threads > 0:
        cv2.setNumThreads(args.threads)
    net = cv2.dnn.readNetFromDarknet(args.cfg, args.weights)
    model = cv2.dnn_DetectionModel(net)
    model.setInputParams(size=(args.size, args.size), scale=1 / 255.0, swapRB=True)
    print(json.dumps({"ready": True, "opencv": cv2.__version__}), flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            answer = search(model, json.loads(line), args.min_score, args.subject_score)
        except Exception as e:  # one bad chunk mustn't stop the detector
            answer = {"error": str(e)}
        print(json.dumps(answer), flush=True)


if __name__ == "__main__":
    main()
