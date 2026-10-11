# presence_ingest: the streamer's cloud detector

A Python Lambda (arm64, Python 3.13) that searches presence-streamer's
chunks for people and animals in the cloud. It serves Pis with too little
memory (under 2 GB) to search them themselves. The spec is
[specs/streamer.md](../specs/streamer.md#cloud-detection).

1. The streamer uploads each chunk, sealed with its device's key, to
   `<identity>/ingest/<device>/<clip>.mp4`, then its job,
   `<clip>.ingest.json`: `{"v": 1, "event", "clip"}`. These are the records a
   phone would store, without the object tags.
2. The user-data bucket notifies this function of each `*.ingest.json`
   (presence_infra/user-data.yaml, `IngestFunctionArn`).
3. The function opens the chunk with the device's key, which it reads from
   `devices/<device>/settings.json`, as the profile's other devices do. It
   searches a frame a second with YOLOv4-tiny (OpenCV), the same model,
   labels and thresholds as the Pi's detector.
4. **No one:** the chunk and the job are deleted. **Someone:** it writes the
   sealed thumbnail (`media/<clip>.jpg`) and copies the recording
   (`media/<clip>.mp4`). Then it writes the clip record, and the event with
   its `objectTags`, last. Only then does it delete ingest's copies.

The job's key decides whose folder and device it is, and the job must
match it. A job can only touch its own folder. The steps can be done again,
so a retry starts over safely.

## Build, test, deploy

```sh
bash scripts/models.sh presence_ingest/IngestFunction/models   # the model, checked by SHA-256
cd presence_ingest && sam build                               # Linux arm64 wheels, whatever the machine (PIP=... for another pip)
python -m pytest -q                                           # with IngestFunction/requirements.txt, pytest and boto3 (the runtime's own) installed
```

Set `MODELS_DIR=<models>` and `PRESENCE_INGEST_PERSON=<photo of a person>`
to also run the real detection test.

`scripts/deploy.sh` deploys it as `<prefix>-ingest` (prod `presence`, RC
`presence-rc`):

1. the user-data stack first (the bucket);
2. this stack;
3. the user-data stack again, with `IngestFunctionArn` (the notification).
