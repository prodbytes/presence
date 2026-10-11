"""People and animals in a video: YOLOv4-tiny (COCO) through OpenCV's DNN
module, on a frame a second, as presence-streamer's own detector
(presence_streamer/detector/presence-detect.py) does on the Pi: the same
model, labels and thresholds.
"""

import os
import time

# OpenCV's FFmpeg reads only local files, and only MP4 (set before cv2 is
# imported): a crafted chunk can't make it open URLs or reach other demuxers.
os.environ.setdefault(
    "OPENCV_FFMPEG_CAPTURE_OPTIONS", "protocol_whitelist;file|format_whitelist;mov,mp4,m4a,3gp,3g2,mj2"
)

import cv2  # noqa: E402
import numpy as np  # noqa: E402

# COCO's 80 classes in the model's order, named as the app names them
# (presence_app/lib/recognition/vision.dart, cocoLabels). The same list as
# the Pi's detector (a test checks).
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

MIN_SCORE = 0.4  # the least a label is noted at
SUBJECT_SCORE = 0.5  # the least a subject counts at (the app's)

MODELS = os.environ.get("MODELS_DIR", os.path.join(os.path.dirname(__file__), "..", "models"))

_model = None


def model():
    """The detector, loaded once per Lambda instance."""
    global _model
    if _model is None:
        net = cv2.dnn.readNetFromDarknet(
            os.path.join(MODELS, "yolov4-tiny.cfg"), os.path.join(MODELS, "yolov4-tiny.weights")
        )
        m = cv2.dnn_DetectionModel(net)
        m.setInputParams(size=(416, 416), scale=1 / 255.0, swapRB=True)
        _model = m
    return _model


class Unreadable(Exception):
    """A video OpenCV can't read."""


MAX_WIDTH, MAX_HEIGHT = 1920, 1080  # the streamer records 1280x720
MAX_DECODED = 5 * 60 * 60  # frames decoded at most: 5 minutes at 60 fps


def search(video: str, thumbnail: str, every_ms: int = 1000, max_frames: int = 600,
           deadline: float | None = None):
    """Searches video (a frame every every_ms) for objects; writes the
    subject's frame, at most 640 px wide, to thumbnail.

    Returns (objects, subject, length_ms): each label's best score and the
    time of its frame, as [{"label", "ms", "score"}]; the best person or
    animal (or None); the video's length.

    Untrusted input is bounded: only MP4 (its ftyp box, and OpenCV's FFmpeg
    told to read only local files and MP4), at most 1920x1080, a sane
    frame rate, at most MAX_DECODED frames decoded, and nothing past
    deadline (time.monotonic()); otherwise Unreadable.
    """
    with open(video, "rb") as f:
        head = f.read(12)
    if len(head) < 12 or head[4:8] != b"ftyp":
        raise Unreadable("not an MP4")
    cap = cv2.VideoCapture(video, cv2.CAP_FFMPEG)
    if not cap.isOpened():
        raise Unreadable("can't open the video")
    width, height = cap.get(cv2.CAP_PROP_FRAME_WIDTH), cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
    if not (0 < width <= MAX_WIDTH and 0 < height <= MAX_HEIGHT):
        cap.release()
        raise Unreadable(f"{width:.0f}x{height:.0f} is too big")
    fps = cap.get(cv2.CAP_PROP_FPS)
    if not 1 <= fps <= 120:
        fps = 30.0
    step = max(1, round(fps * every_ms / 1000))
    best = {}  # label -> (score, ms)
    subject = None  # (score, label, ms, frame)
    index = searched = 0
    try:
        while searched < max_frames and index < MAX_DECODED and cap.grab():
            if deadline is not None and time.monotonic() > deadline:
                raise Unreadable("took too long")
            if index % step == 0:
                ok, frame = cap.retrieve()
                if ok:
                    searched += 1
                    ms = int(index * 1000 / fps)
                    h, w = frame.shape[:2]
                    if w > 1280:
                        frame = cv2.resize(frame, (1280, round(h * 1280 / w)), interpolation=cv2.INTER_AREA)
                    classes, scores, _ = model().detect(frame, confThreshold=MIN_SCORE, nmsThreshold=0.4)
                    for c, s in zip(np.array(classes).flatten(), np.array(scores).flatten()):
                        c, s = int(c), float(s)
                        if not 0 <= c < len(LABELS):
                            continue
                        label = LABELS[c]
                        if label not in best or s > best[label][0]:
                            best[label] = (s, ms)
                        if label in SUBJECTS and s >= SUBJECT_SCORE and (subject is None or s > subject[0]):
                            subject = (s, label, ms, frame)
            index += 1
    finally:
        cap.release()
    if index == 0:
        raise Unreadable("no frames")
    objects = [{"label": l, "ms": ms, "score": round(s, 3)} for l, (s, ms) in sorted(best.items())]
    if subject is None:
        return objects, None, int(index * 1000 / fps)
    score, label, ms, frame = subject
    h, w = frame.shape[:2]
    if w > 640:
        frame = cv2.resize(frame, (640, round(h * 640 / w)), interpolation=cv2.INTER_AREA)
    cv2.imwrite(thumbnail, frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
    return objects, {"label": label, "ms": ms, "score": round(score, 3)}, int(index * 1000 / fps)
