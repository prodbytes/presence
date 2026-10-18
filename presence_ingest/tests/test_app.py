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


class ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class FakeS3:
    """The versioned bucket: current objects by key, their versions, the old
    versions a plain delete or an overwrite keeps, and the operations done."""

    class exceptions:
        NoSuchKey = NoSuchKey
        ClientError = ClientError

    def __init__(self):
        self.objects, self.ops = {}, []
        self.vids, self.noncurrent, self.count = {}, [], 0
        self.deny_versions = False

    def version(self, key):
        if key not in self.vids:
            self.count += 1
            self.vids[key] = f"v{self.count}"
        return self.vids[key]

    def replaced(self, key):
        if key in self.objects:
            self.noncurrent.append((key, self.version(key)))
        self.vids.pop(key, None)

    def get_object(self, Bucket, Key):
        if Key not in self.objects:
            raise NoSuchKey(Key)
        data = self.objects[Key]
        body = io.BytesIO(data)
        body.iter_chunks = lambda n: iter(lambda: body.read(n), b"")
        return {"ContentLength": len(data), "Body": body, "VersionId": self.version(Key)}

    def head_object(self, Bucket, Key):
        self.ops.append(f"head {Key}")
        if Key not in self.objects:
            raise ClientError("404")
        return {"ContentLength": len(self.objects[Key]), "VersionId": self.version(Key)}

    def put_object(self, Bucket, Key, Body, ContentType, StorageClass):
        assert StorageClass == "INTELLIGENT_TIERING"
        self.ops.append(f"put {Key}")
        self.replaced(Key)
        self.objects[Key] = Body

    def copy_object(self, Bucket, Key, CopySource, StorageClass, MetadataDirective):
        self.ops.append(f"copy {CopySource['Key']} {Key}")
        self.replaced(Key)
        self.objects[Key] = self.objects[CopySource["Key"]]

    def delete_object(self, Bucket, Key, VersionId=None):
        if VersionId is None:  # a delete marker: the data stays, an old version
            self.ops.append(f"delete {Key}")
            self.replaced(Key)
            self.objects.pop(Key, None)
            return
        if self.deny_versions:
            raise ClientError("AccessDenied")
        self.ops.append(f"delete {Key} {VersionId}")
        if self.vids.get(Key) == VersionId:
            self.objects.pop(Key, None)
            self.vids.pop(Key)
        else:
            self.noncurrent = [(k, v) for k, v in self.noncurrent if (k, v) != (Key, VersionId)]

    def kept(self):
        """Ingest's objects still in the bucket, current or old versions."""
        return [k for k in list(self.objects) + [k for k, _ in self.noncurrent] if "/ingest/" in k]


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
        f"delete {root}ingest/{DEVICE}/{CLIP}.mp4 v2",
        f"delete {root}ingest/{DEVICE}/{CLIP}.ingest.json v1",
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
    assert s3.kept() == []  # for good: no old versions either
    # Compact, one line, as the app writes them.
    assert b"\n" not in s3.objects[f"{root}clips/year=2026/day=269/{CLIP}.json"]


def test_no_one_there_is_deleted(tmp_path, found):
    found["objects"] = [{"label": "car", "ms": 0, "score": 0.9}]
    s3 = bucket()
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "no one"
    assert [k for k in s3.objects if "/devices/" not in k] == []
    assert s3.noncurrent == []


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
    assert s3.kept() == []  # for good: no old versions either


def test_without_the_devices_key_it_is_retried(tmp_path, found):
    s3 = bucket()
    del s3.objects[f"{IDENTITY}/devices/{DEVICE}/settings.json"]
    with pytest.raises(LookupError):
        app.process(s3, "b", JOB_KEY, str(tmp_path))
    assert f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.ingest.json" in s3.objects


def test_a_bad_jobs_unread_chunk_is_deleted_for_good(tmp_path, found):
    s3 = bucket(job_record={"v": 2})
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "bad job"
    chunk = f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.mp4"
    assert s3.ops == [f"head {chunk}", f"delete {chunk} v2", f"delete {JOB_KEY} v1"]
    assert s3.kept() == []


def test_a_missing_chunk_isnt_deleted(tmp_path, found):
    s3 = bucket(job_record={"v": 2})
    del s3.objects[f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.mp4"]
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "bad job"
    assert s3.ops == [f"head {IDENTITY}/ingest/{DEVICE}/{CLIP}.mp4", f"delete {JOB_KEY} v1"]
    assert s3.kept() == []


def test_a_newer_upload_of_the_job_is_left(tmp_path, found):
    s3 = bucket()
    folder = app.Folder(s3, "b", IDENTITY)
    job_key = f"ingest/{DEVICE}/{CLIP}.ingest.json"
    folder.get(job_key, app.MAX_JOB)
    s3.put_object(Bucket="b", Key=JOB_KEY, Body=b"{}", ContentType="application/json",
                  StorageClass="INTELLIGENT_TIERING")
    folder.delete(job_key)
    assert s3.objects[JOB_KEY] == b"{}"  # its own notification does it
    assert s3.noncurrent == []  # the version read is gone for good


def test_without_leave_to_delete_versions_it_deletes_as_before(tmp_path, found, capsys):
    found["subject"] = {"label": "dog", "ms": 0, "score": 0.9}
    s3 = bucket()
    s3.deny_versions = True  # the stage's boundary without DeleteObjectVersion
    assert app.process(s3, "b", JOB_KEY, str(tmp_path)) == "stored"
    assert not any("/ingest/" in k for k in s3.objects)
    assert sorted(k for k, _ in s3.noncurrent if "/ingest/" in k) == sorted([JOB_KEY, f"{IDENTITY}/ingest/{DEVICE}/{CLIP}.mp4"])
    assert "version kept" in capsys.readouterr().out


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
    assert s3.kept() == []  # for good: no old versions either


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
