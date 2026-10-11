"""The cloud detector for presence-streamer's ingest (specs/streamer.md).

A streamer on a Pi with too little memory to detect on the device uploads
each chunk, sealed, to `<identity>/ingest/<device>/<clip>.mp4`, then a job,
`<clip>.ingest.json`: the clip's record and its event, as a phone would
store them, but for what detection adds. S3 calls this function for each
job. It opens the chunk with the device's key (from its settings in the
same folder, as the profile's other devices do) and looks for people and
animals:

- none: the chunk and the job are deleted;
- some: the sealed thumbnail goes to `media/<clip>.jpg`, the recording is
  copied to `media/<clip>.mp4`, the clip record and the event (with its
  object tags) to their day partitions, and then ingest's copies are
  deleted.

Everything is checked against the job's key, which says whose folder and
device it is: a job can only touch its own folder. Each step can be done
again, so a retry (Lambda's, for an error) starts over safely; the job is
deleted last.
"""

import base64
import json
import os
import re
import shutil
import tempfile
import time
import urllib.parse
from datetime import datetime, timezone

import boto3

from . import detect, seal

JOB = re.compile(
    r"^(?P<identity>[a-z]{2}(?:-[a-z]+)+-[0-9]:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
    r"/ingest/(?P<device>[a-z]+_[a-z]+_[a-z]+)/(?P<clip>[A-Za-z0-9_-]{1,100})\.ingest\.json$"
)
SAFE_ID = re.compile(r"^[A-Za-z0-9_:-]{1,128}$")

MAX_JOB = 64 * 1024
MAX_VIDEO = 256 * 1024 * 1024  # 5 minutes at 2.5 Mbit/s is under 100 MB
# Times between 2020 and 2100 (ms).
MIN_TIME, MAX_TIME = 1577836800000, 4102444800000
# The search stops this long before the function's timeout, so a chunk
# that takes too long is given up (deleted), not retried.
SPARE_MS = 30_000
# One job's files, emptied first: a run killed mid-way (timeout, memory)
# leaves its files, and Lambda doesn't clear /tmp.
WORK = os.path.join(tempfile.gettempdir(), "ingest")
OBJECT_SCORE = 0.6  # the least an object tag needs (the app's)


def log(**fields):
    print(json.dumps(fields, separators=(",", ":")), flush=True)


class Folder:
    """A profile's folder in the bucket: keys are relative to it."""

    def __init__(self, s3, bucket: str, identity: str):
        self.s3, self.bucket, self.root = s3, bucket, identity + "/"

    def get(self, key: str, limit: int) -> bytes | None:
        try:
            obj = self.s3.get_object(Bucket=self.bucket, Key=self.root + key)
        except self.s3.exceptions.NoSuchKey:
            return None
        if obj["ContentLength"] > limit:
            raise ValueError(f"{key} is too big ({obj['ContentLength']} bytes)")
        return obj["Body"].read()

    def download(self, key: str, path: str) -> bool:
        try:
            head = self.s3.get_object(Bucket=self.bucket, Key=self.root + key)
        except self.s3.exceptions.NoSuchKey:
            return False
        if head["ContentLength"] > MAX_VIDEO:
            raise ValueError(f"{key} is too big ({head['ContentLength']} bytes)")
        with open(path, "wb") as f:
            for part in head["Body"].iter_chunks(1024 * 1024):
                f.write(part)
        return True

    def put(self, key: str, body: bytes, content_type: str):
        self.s3.put_object(
            Bucket=self.bucket, Key=self.root + key, Body=body,
            ContentType=content_type, StorageClass="INTELLIGENT_TIERING",
        )

    def copy(self, src: str, dst: str):
        self.s3.copy_object(
            Bucket=self.bucket, Key=self.root + dst,
            CopySource={"Bucket": self.bucket, "Key": self.root + src},
            StorageClass="INTELLIGENT_TIERING", MetadataDirective="COPY",
        )

    def delete(self, key: str):
        self.s3.delete_object(Bucket=self.bucket, Key=self.root + key)


def day_prefix(root: str, ms: int) -> str:
    t = datetime.fromtimestamp(ms / 1000, tz=timezone.utc)
    return f"{root}/year={t.year}/day={t.timetuple().tm_yday:03d}/"


def to_json(record: dict) -> bytes:
    """A record as the app uploads it: compact, one line."""
    return json.dumps(record, separators=(",", ":"), ensure_ascii=False).encode()


class BadJob(Exception):
    """A job that can't be done: deleted, with its chunk."""


def check(job: dict, device: str, clip_id: str) -> tuple[dict, dict]:
    """The job's event and clip record, checked against its key, and that
    they can be written (so nothing fails half-way, after media is up)."""
    if not isinstance(job, dict) or job.get("v") != 1:
        raise BadJob("not a job")
    event, clip = job.get("event"), job.get("clip")
    if not isinstance(event, dict) or not isinstance(clip, dict):
        raise BadJob("no event or clip")
    if clip.get("id") != clip_id or event.get("clipId") != clip_id or clip.get("eventId") != event.get("id"):
        raise BadJob("the clip isn't the job's")
    if event.get("deviceId") != device or event.get("type") != "clip_requested":
        raise BadJob("the event isn't the device's clip")
    if not isinstance(event.get("id"), str) or not SAFE_ID.fullmatch(event["id"]):
        raise BadJob("unsafe event ID")
    for record, field in ((event, "time"), (clip, "requestedAt")):
        if type(record.get(field)) is not int or not MIN_TIME <= record[field] <= MAX_TIME:
            raise BadJob(f"no {field}")
    try:
        to_json(event), to_json(clip)
    except (UnicodeEncodeError, ValueError, TypeError) as e:
        raise BadJob(f"not writable: {e}") from None
    return event, clip


def device_key(folder: Folder, device: str) -> bytes:
    """The device's media key, from its settings (as the app reads it)."""
    try:
        data = folder.get(f"devices/{device}/settings.json", MAX_JOB)
        if data is None:
            raise LookupError(f"no settings for {device} yet")
        settings = json.loads(data)
        key = base64.b64decode(settings.get("mediaKey") or "", validate=True)
    except LookupError:
        raise
    except Exception as e:  # not JSON, not an object, not base64, too big
        raise LookupError(f"{device}'s settings don't read: {e}") from None
    if settings.get("deviceId") != device or len(key) != 32:
        raise LookupError(f"{device}'s settings have no media key")
    return key


def process(s3, bucket: str, key: str, tmp: str, deadline: float | None = None) -> str:
    """Does the job at key; says what became of it. deadline
    (time.monotonic()) bounds the search."""
    m = JOB.fullmatch(key)
    if not m:
        return "ignored"
    identity, device, clip_id = m["identity"], m["device"], m["clip"]
    folder = Folder(s3, bucket, identity)
    job_key = f"ingest/{device}/{clip_id}.ingest.json"
    video_key = f"ingest/{device}/{clip_id}.mp4"

    try:
        data = folder.get(job_key, MAX_JOB)
    except ValueError:
        data = b"too big"
    if data is None:
        return "gone"  # done already (S3 may call twice)
    try:
        event, clip = check(json.loads(data), device, clip_id)
    except (BadJob, ValueError) as e:
        log(at="ingest", key=key, outcome="bad job", why=str(e))
        folder.delete(video_key)
        folder.delete(job_key)
        return "bad job"

    sealed = os.path.join(tmp, "chunk.sealed")
    plain = os.path.join(tmp, "chunk.mp4")
    thumb = os.path.join(tmp, "thumb.jpg")
    try:
        downloaded = folder.download(video_key, sealed)
    except ValueError as e:  # too big
        log(at="ingest", key=key, outcome="broken", why=str(e))
        folder.delete(video_key)
        folder.delete(job_key)
        return "broken"
    if not downloaded:
        # Its chunk was deleted, or stored, before a crash kept the job from
        # being deleted.
        folder.delete(job_key)
        return "no chunk"
    key_bytes = device_key(folder, device)  # missing: retried
    try:
        with open(sealed, "rb") as f:
            _, key_id, _ = seal.read_header(f)
        if key_id != device:
            raise seal.Broken("sealed by another device")
        seal.open_file(sealed, plain, key_bytes)
        os.remove(sealed)
        started = time.monotonic()
        objects, subject, _ = detect.search(plain, thumb, deadline=deadline)
        searched_ms = int((time.monotonic() - started) * 1000)
    except (seal.Broken, detect.Unreadable) as e:
        log(at="ingest", key=key, outcome="broken", why=str(e))
        folder.delete(video_key)
        folder.delete(job_key)
        return "broken"

    if subject is None:
        folder.delete(video_key)
        folder.delete(job_key)
        log(at="ingest", key=key, outcome="no one", searchedMs=searched_ms)
        return "no one"

    tags = [o for o in objects if o["score"] >= OBJECT_SCORE]
    if not any(t["label"] == subject["label"] for t in tags):
        tags.append(subject)
    event = dict(event, objectTags=sorted(tags, key=lambda t: t["label"]))

    with open(thumb, "rb") as f:
        folder.put(f"media/{clip_id}.jpg", seal.seal_bytes(f.read(), key_bytes, device), "application/octet-stream")
    folder.copy(video_key, f"media/{clip_id}.mp4")
    folder.put(day_prefix("clips", clip["requestedAt"]) + f"{clip_id}.json", to_json(clip), "application/json")
    # Last of the records, so the event shows once its media is there.
    folder.put(day_prefix("events", event["time"]) + f"{event['id']}.json", to_json(event), "application/json")
    folder.delete(video_key)
    folder.delete(job_key)
    log(at="ingest", key=key, outcome="stored", subject=subject, searchedMs=searched_ms, event=event["id"])
    return "stored"


_s3 = None


def handler(event, context):
    """S3's ObjectCreated notifications for `*.ingest.json` (template.yaml)."""
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3")
    bucket = os.environ["BUCKET"]
    remaining = context.get_remaining_time_in_millis() if context else 300_000
    deadline = time.monotonic() + max(remaining - SPARE_MS, 10_000) / 1000
    results = []
    for record in event.get("Records", []):
        s3 = record.get("s3", {})
        if s3.get("bucket", {}).get("name") != bucket:
            continue
        key = urllib.parse.unquote_plus(s3.get("object", {}).get("key", ""))
        shutil.rmtree(WORK, ignore_errors=True)
        os.makedirs(WORK)
        try:
            results.append(process(_s3, bucket, key, WORK, deadline))
        finally:
            shutil.rmtree(WORK, ignore_errors=True)
    return {"results": results}
