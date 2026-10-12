import base64
import io
import json
import os
import re

import pytest

from ingest import app, detect, seal

IDENTITY = "us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b"
OTHER = "us-east-1:11111111-2222-4333-8444-555555555555"
DEVICE = "able_adept_gadget"
CLIP = "hmnhfi8000-12ifwo6"
KEY = bytes(range(32))
TIME = 1790436872000  # 2026-09-26


class NoSuchKey(Exception):
    pass


class FakeS3:
    """The bucket: objects by key, and the operations done."""

    class exceptions:
        NoSuchKey = NoSuchKey

    def __init__(self):
        self.objects, self.ops = {}, []

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise NoSuchKey(Key)
        data = self.objects[Key]
        body = io.BytesIO(data)
        body.iter_chunks = lambda n: iter(lambda: body.read(n), b"")
        return {"ContentLength": len(data), "Body": body}

    def put_object(self, Bucket, Key, Body, ContentType, StorageClass):
        assert StorageClass == "INTELLIGENT_TIERING"
        self.ops.append(f"put {Key}")
        self.objects[Key] = Body

    def copy_object(self, Bucket, Key, CopySource, StorageClass, MetadataDirective):
        self.ops.append(f"copy {CopySource['Key']} {Key}")
        self.objects[Key] = self.objects[CopySource["Key"]]

    def delete_object(self, Bucket, Key):
        self.ops.append(f"delete {Key}")
        self.objects.pop(Key, None)


def job(**changes):
    event = {
        "id": "hmnhfi8000-0aaaaaa", "type": "clip_requested", "title": "Motion detected",
        "detail": "Raspberry Pi camera", "time": TIME, "cameraId": "libcamera", "deviceId": DEVICE,
        "userId": "42", "profileId": "automatic_paranoid_axolotl", "location": None, "os": "Linux",
        "clipId": CLIP, "clipState": "complete", "trigger": "motion", "objectTags": [],
    }
    clip = {
        "id": CLIP, "eventId": event["id"], "cameraId": "libcamera", "cameraLabel": "Raspberry Pi camera",
        "requestedAt": TIME, "beforeMs": 0, "afterMs": 30000, "supported": True, "state": "complete",
        "full": {"mediaId": CLIP + "-full", "startMs": 0, "endMs": 30000, "mimeType": "video/mp4"},
    }
    j = {"v": 1, "event": event, "clip": clip}
    for k, v in changes.items():
        part, field = k.split("__")
        j[part][field] = v
    return j


def bucket(identity=IDENTITY, job_record=None, video=b"video bytes", key=KEY):
    s3 = FakeS3()
    root = identity + "/"
    s3.objects[root + f"devices/{DEVICE}/settings.json"] = json.dumps(
        {"deviceId": DEVICE, "config": {"version": 1}, "mediaKey": base64.b64encode(key).decode()}
    ).encode()
    s3.objects[root + f"ingest/{DEVICE}/{CLIP}.mp4"] = seal.seal_bytes(video, KEY, DEVICE)
    s3.objects[root + f"ingest/{DEVICE}/{CLIP}.ingest.json"] = json.dumps(job_record or job()).encode()
    return s3


JOB_KEY = f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.ingest.json"


@pytest.fixture
def found(monkeypatch):
    """Detection that finds what the test says, writing a thumbnail."""
    result = {}

    def search(video, thumbnail, deadline=None):
        with open(video, "rb") as f:
            result["video"] = f.read()
        if result.get("subject"):
            with open(thumbnail, "wb") as f:
                f.write(b"jpeg")
        return result.get("objects", []), result.get("subject"), 30000

    monkeypatch.setattr(detect, "search", search)
    return result


def test_a_subject_is_stored_as_a_phone_would(tmp_path, found):
    found["objects"] = [{"label": "bicycle", "ms": 2000, "score": 0.7}, {"label": "cup", "ms": 0, "score": 0.45},
                        {"label": "human", "ms": 1000, "score": 0.55}]
    found["subject"] = {"label": "human", "ms": 1000, "score": 0.55}
    s3 = bucket()
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "stored"
    assert found["video"] == b"video bytes"  # opened with the device's key
    root = IDENTITY + "/"
    assert s3.ops == [
        f"put {root}media/{CLIP}.jpg",
        f"copy {root}ingest/{DEVICE}/{CLIP}.mp4 {root}media/{CLIP}.mp4",
        f"put {root}clips/year=2026/day=269/{CLIP}.json",
        f"put {root}events/year=2026/day=269/hmnhfi8000-0aaaaaa.json",
        f"delete {root}ingest/{DEVICE}/{CLIP}.mp4",
        f"delete {root}ingest/{DEVICE}/{CLIP}.ingest.json",
    ]
    event = json.loads(s3.objects[f"{root}events/year=2026/day=269/hmnhfi8000-0aaaaaa.json"])
    # 0.6 for object tags; the subject at its own score.
    assert event["objectTags"] == [{"label": "bicycle", "ms": 2000, "score": 0.7},
                                   {"label": "human", "ms": 1000, "score": 0.55}]
    assert event["deviceId"] == DEVICE and event["userId"] == "42"
    thumb = f"{tmp_path}/t"
    with open(thumb, "wb") as f:
        f.write(s3.objects[f"{root}media/{CLIP}.jpg"])
    seal.open_file(thumb, f"{tmp_path}/t.jpg", KEY)
    with open(f"{tmp_path}/t.jpg", "rb") as f:
        assert f.read() == b"jpeg"
    assert not any("/ingest/" in k for k in s3.objects)
    # Compact, one line, as the app writes them.
    assert b"\n" not in s3.objects[f"{root}clips/year=2026/day=269/{CLIP}.json"]


def test_no_one_there_is_deleted(tmp_path, found):
    found["objects"] = [{"label": "car", "ms": 0, "score": 0.9}]
    s3 = bucket()
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "no one"
    assert [k for k in s3.objects if "/devices/" not in k] == []


def test_a_job_twice_is_done_once(tmp_path, found):
    found["subject"] = {"label": "dog", "ms": 0, "score": 0.9}
    s3 = bucket()
    app.process(s3, "b", JOB_KEY, str(tmp_path))
    ops = list(s3.ops)
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "gone"
    assert s3.ops == ops


def test_a_broken_chunk_is_deleted(tmp_path, found):
    s3 = bucket()
    s3.objects[f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.mp4"] = b"not sealed"
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "broken"
    assert not any("/ingest/" in k for k in s3.objects)


def test_without_the_devices_key_it_is_retried(tmp_path, found):
    s3 = bucket()
    del s3.objects[f"{IDENTITY}/devices/{DEVICE}/settings.json"]
    with pytest.raises(LookupError):
        app.process(s3, "b", JOB_KEY, str(tmp_path))
    assert f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.ingest.json" in s3.objects


@pytest.mark.parametrize("bad", [
    {"event__time": 10**20},
    {"event__time": True},
    {"event__title": "\ud800"},
    {"event__id": "x.ingest"},
    {"event__deviceId": "other_device_name"},
    {"event__clipId": "another-clip"},
    {"clip__id": "another-clip"},
    {"event__id": "../../x"},
    {"event__type": "generic"},
    {"event__time": "soon"},
])
def test_a_job_that_isnt_its_keys_is_refused(tmp_path, found, bad):
    found["subject"] = {"label": "human", "ms": 0, "score": 0.9}
    s3 = bucket(job_record=job(**bad))
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "bad job"
    assert not any("/events/" in k or "/media/" in k for k in s3.objects)


def test_a_job_too_big_is_refused(tmp_path, found):
    s3 = bucket()
    s3.objects[JOB_KEY] = b"{" + b" " * app.MAX_JOB + b"}"
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "bad job"
    assert not any("/ingest/" in k for k in s3.objects)


@pytest.mark.parametrize("settings", [b"not json", b"[]", b'{"deviceId": "able_adept_gadget", "mediaKey": "%%%"}'])
def test_unreadable_settings_are_retried(tmp_path, found, settings):
    s3 = bucket()
    s3.objects[f"{IDENTITY}/devices/{DEVICE}/settings.json"] = settings
    with pytest.raises(LookupError):
        app.process(s3, "b", JOB_KEY, str(tmp_path))


def test_only_its_own_folder(tmp_path, found):
    found["subject"] = {"label": "human", "ms": 0, "score": 0.9}
    s3 = bucket()
    app.process(s3, "b", JOB_KEY, str(tmp_path))
    assert all(op.split()[1].startswith(IDENTITY + "/") for op in s3.ops)
    for key in [f"{OTHER}/../{IDENTITY}/ingest/{DEVICE}/{CLIP}.ingest.json", f"x/ingest/{DEVICE}/{CLIP}.ingest.json",
                f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.mp4", f"{IDENTITY}/ingest/{DEVICE}/a/b.ingest.json",
                JOB_KEY + "\n"]:
        assert app.process(s3, "b", key, str(tmp_path)) == "ignored"


def test_handler_takes_s3_notifications(tmp_path, found, monkeypatch):
    s3 = bucket()
    monkeypatch.setattr(app, "_s3", s3)
    monkeypatch.setenv("BUCKET", "b")
    encoded = JOB_KEY.replace(":", "%3A")
    monkeypatch.setattr(app, "WORK", str(tmp_path / "work"))
    (tmp_path / "work").mkdir()
    (tmp_path / "work" / "left-by-a-killed-run").write_bytes(b"x" * 1000)
    out = app.handler({"Records": [
        {"s3": {"bucket": {"name": "b"}, "object": {"key": encoded}}},
        {"s3": {"bucket": {"name": "another"}, "object": {"key": encoded}}},
    ]}, None)
    assert out == {"results": ["no one"]}
    assert not (tmp_path / "work").exists()  # emptied before, removed after


def test_labels_are_the_pi_detectors():
    src = open(os.path.join(os.path.dirname(__file__), "..", "..", "presence_streamer", "detector",
                            "presence-detect.py")).read()
    labels = re.search(r"LABELS = \[(.*?)\]", src, re.S).group(1)
    subjects = re.search(r"SUBJECTS = \{(.*?)\}", src, re.S).group(1)
    assert re.findall(r'"([^"]+)"', labels) == detect.LABELS
    assert set(re.findall(r'"([^"]+)"', subjects)) == detect.SUBJECTS


@pytest.mark.skipif(not os.environ.get("PRESENCE_INGEST_PERSON"), reason="set PRESENCE_INGEST_PERSON to a photo of a person")
def test_real_detection(tmp_path):
    import cv2
    import numpy as np

    person = cv2.imread(os.environ["PRESENCE_INGEST_PERSON"])
    video = str(tmp_path / "v.mp4")
    out = cv2.VideoWriter(video, cv2.VideoWriter_fourcc(*"mp4v"), 10, (640, 480))
    for i in range(30):
        frame = np.full((480, 640, 3), 128, np.uint8) if i < 15 else cv2.resize(person, (640, 480))
        out.write(frame)
    out.release()
    objects, subject, length = detect.search(video, str(tmp_path / "t.jpg"))
    assert subject and subject["label"] == "human" and subject["ms"] >= 1500
    assert os.path.getsize(tmp_path / "t.jpg") > 1000
    assert 2900 <= length <= 3100


def test_the_streamers_job_passes():
    # What presence-streamer uploads (presence_streamer/internal/records).
    path = os.path.join(os.path.dirname(__file__), "..", "..", "presence_streamer", "testdata", "job-fixture.json")
    with open(path) as f:
        event, clip = app.check(json.load(f), "able_adept_gadget", "hmnhfi8000-12ifwo6")
    assert event["time"] == clip["requestedAt"] and event["objectTags"] == []


def test_untrusted_videos_are_refused(tmp_path):
    import cv2
    import numpy as np

    not_mp4 = tmp_path / "x.mkv"
    not_mp4.write_bytes(b"\x1aE\xdf\xa3" + b"\x00" * 100)  # Matroska
    with pytest.raises(detect.Unreadable, match="not an MP4"):
        detect.search(str(not_mp4), str(tmp_path / "t.jpg"))

    big = str(tmp_path / "big.mp4")
    out = cv2.VideoWriter(big, cv2.VideoWriter_fourcc(*"mp4v"), 10, (2560, 1440))
    for _ in range(3):
        out.write(np.zeros((1440, 2560, 3), np.uint8))
    out.release()
    with pytest.raises(detect.Unreadable, match="too big"):
        detect.search(big, str(tmp_path / "t.jpg"))

    ok = str(tmp_path / "ok.mp4")
    out = cv2.VideoWriter(ok, cv2.VideoWriter_fourcc(*"mp4v"), 10, (320, 240))
    for _ in range(30):
        out.write(np.zeros((240, 320, 3), np.uint8))
    out.release()
    import time
    with pytest.raises(detect.Unreadable, match="too long"):
        detect.search(ok, str(tmp_path / "t.jpg"), deadline=time.monotonic() - 1)


def test_dark_frames_are_brightened_and_lit_ones_kept():
    import cv2
    import numpy as np

    rng = np.random.default_rng(0)
    dark = rng.integers(0, 25, (72, 128, 3), dtype=np.uint8)  # a dim room: mean about 12
    bright = detect.brighten(dark)
    assert cv2.cvtColor(bright, cv2.COLOR_BGR2GRAY).mean() > 80
    lit = rng.integers(60, 200, (72, 128, 3), dtype=np.uint8)
    assert detect.brighten(lit) is lit


def test_the_pi_detector_brightens_the_same():
    import importlib.util

    import numpy as np

    path = os.path.join(os.path.dirname(__file__), "..", "..", "presence_streamer", "detector", "presence-detect.py")
    spec = importlib.util.spec_from_file_location("presence_detect", path)
    pi = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pi)
    frame = np.random.default_rng(1).integers(0, 30, (48, 64, 3), dtype=np.uint8)
    assert pi.DARK == detect.DARK
    assert (pi.brighten(frame) == detect.brighten(frame)).all()
