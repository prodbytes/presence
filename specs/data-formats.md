# Recording and data formats

How Presence records video and metadata, and how they're laid out on S3 so
the metadata can be queried there with SQL (Athena) without reading a
single video. Where they're uploaded, and when, is in
[Cloud sync](cloud-sync.md).

## Video

Every clip is one file: the recording from the keyframe at or before the
clip's window to its end. The window itself (`startMs`, `endMs` in the clip
record) says which part of the file the clip is; players start there. See
[Clips](clips.md) and [Platforms](platforms.md).

| | Web | Android | iOS |
|---|---|---|---|
| Recorder | `MediaRecorder`, a pool of them ([Clips](clips.md)) | Camera2 → `MediaCodec` → `MediaMuxer` | `AVCaptureSession` → VideoToolbox → `AVAssetWriter` |
| Container | **WebM** (`video/webm`); Safari: MP4 | **MP4** (`video/mp4`) | **MP4** (`video/mp4`) |
| Video codec | **VP8** (`video/webm;codecs=vp8,opus`), else VP9, else the browser's default | **H.264** (AVC), hardware | **H.264** High, hardware, no B-frames |
| Size | the camera's default (none is asked for) | up to 1280×720 | 1280×720, frames turned to portrait |
| Frame rate | up to 30 fps, down to 10 in low light (a hint) | variable, up to 30 fps (5–30) | 30 fps, 10 in low light |
| Video bit rate | the browser's default | 2.5 Mbit/s at 1280 px wide, else 1.5 | 2.5 Mbit/s average |
| Keyframes | every 5 s (asked for; ignored by some browsers) | every 1 s | every 1 s |
| Audio | **Opus**, when there's a microphone | **AAC-LC**, mono, 64 kbit/s, the microphone's rate (44.1 kHz) | **AAC**, 64 kbit/s, the microphone's rate and channels |
| Rotation | upright | an MP4 rotation flag (sensor orientation) | upright (portrait frames) |

- Measured on the bucket on 2026-10-02: 92 web clips (WebM), 12.7 MB on
  average (6.8–14.9 MB), about 3.4 Mbit/s for a 30 s clip.
- **Images** are JPEG: the clip's **thumbnail** (the camera's frame when
  the clip was asked for, about 20 KB) and each **tagged frame** (the frame
  someone tagged on, at most 960 px wide, about 50 KB; at most 1280 px for
  frames recognition tagged, a few times bigger, as sharp as the
  recording for later matching).

## Metadata

Everything else is JSON, written so a query engine can read it as is:

- **UTF-8 JSON, one object per file, on one line** (compact, as JSON
  Lines), so Athena's JSON SerDe reads each file as one row. Never
  pretty-printed.
- **No binary data:** images and recordings are separate objects (under
  `media/`); records refer to them by ID. The local records' `thumbnail`
  and `frames` are left out of what's uploaded.
- **Times** are integers, **milliseconds since the Unix epoch, UTC**
  (`time`, `requestedAt`, `updatedAt`); **durations and offsets** are
  integer milliseconds, named `…Ms` (`beforeMs`, `startMs`).
- **Names** are camelCase and unique ignoring case (Athena lowercases
  them). **IDs** are strings, **enums** lowercase strings (`type`,
  `trigger`, `source`), positions on a frame fractions from 0 to 1, scores
  and confidences from 0 to 1.
- **Optional fields** are left out or `null`; queries read both as null.
  New fields may be added; existing ones keep their name, type and meaning.
- **Reading them** (the app, from storage or the bucket) goes through one
  codec, `Records` ([records.dart](../presence_app/lib/storage/records.dart)),
  that tolerates damage rather than trusting it: an event needs a string
  `id` and an integer `time`, a clip record a string `id`; an integral
  double (`6.0`) counts as the integer; a text field of another type is
  dropped; a recording reference (`past`, `full`) needs a `mediaId` of
  `[A-Za-z0-9_-]` (it names a file on Android) or it's dropped;
  durations default to 0. From the bucket, event, clip and frame IDs must
  also match `[A-Za-z0-9_.:-]{1,128}` without `..` (they go into keys).
  A record that fails is skipped and logged, never the whole history or
  sync pass with it. Settings need `deviceId` and `config`.

### Event record — `events/year=YYYY/day=DDD/<id>.json`

One per event (see [Events](events.md)), about 100–600 bytes:

| Field | Type | |
|---|---|---|
| `id` | string | the event's ID |
| `type` | string | `app_started`, `capture_all`, `clip_requested`, `subject_suggestion`, `generic`… |
| `title`, `detail` | string | as shown; `detail` may be null |
| `time` | integer (ms, UTC) | when it happened; also its partition |
| `cameraId`, `deviceId`, `userId`, `profileId` | string | see [Devices, users and places](devices-users-places.md); `profileId` is missing on events uploaded before 2026-10-05 |
| `location` | object | `{lat, lng, accuracy, source, time}`: where the device was (see [Device location](device-location.md)); may be null |
| `os` | string | the recording device's operating system: `Android`, `iOS`, `macOS`, `Windows`, `Linux`, or `Web (<browser>, <system>)` (see [Events](events.md)); missing on events saved before 2026-10-06 |
| `deletedAt` | integer (ms, UTC) | when the event was deleted, alone from its details or with its device ([Device deletion](device-deletion.md)): the event is hidden on every device; missing on events that aren't deleted. Once set it stays (a copy without it doesn't undo it) |

Clip events (`clip_requested`) add:

| Field | Type | |
|---|---|---|
| `clipId` | string | the clip record's ID |
| `clipState` | string | `partial` (only the before part) or `complete` |
| `trigger` | string | `manual`, `motion`, `scheduled`, `startup` or `all` ([Capture all](camera.md#capture-all)) |
| `annotations` | array of objects | the people and pets tagged: `{id, name, x, y, frameId, frameMs, source, confidence}`; `source` is `detected`, `suggested` or `confirmed` (left out: tagged by someone); see [Clips](clips.md) |
| `objectTags` | array of objects | what recognition saw: `{label, ms, score}`, once per label; left out until searched (see [Subject recognition](recognition.md)) |

[Event flags](event-flags.md) (such as *unidentified*) aren't stored:
they're worked out from `annotations` and `objectTags` wherever the event
is read.

"Is this Rex?" events (`subject_suggestion`) add `clipEventId`,
`annotationId`, `subjectName` and `confidence`.

### Clip record — `clips/year=YYYY/day=DDD/<clipId>.json`

One per clip, about 400 bytes, in the same day partition as its event:

| Field | Type | |
|---|---|---|
| `id`, `eventId` | string | the clip and its event |
| `cameraId`, `cameraLabel` | string | the camera |
| `requestedAt` | integer (ms, UTC) | when Clip was pressed (or motion, the schedule…): its event's `time`, whose day is the record's partition |
| `beforeMs`, `afterMs` | integer (ms) | the clip's length before and after that |
| `supported` | boolean | whether the camera could record |
| `state` | string | `recording`, `complete` or `failed`; only `complete` clips are uploaded |
| `full` (or `past`) | object | the recording: `{mediaId, startMs, endMs, mimeType}`, the window inside the file and its type; `past` when only the before part was saved |

### Device settings — `devices/<deviceId>/settings.json`

`{deviceId, profileId, updatedAt, config, location}`, in the profile's
folder: `config` as in [Configuration](configuration.md), `profileId` the
profile they were synced with, and `location` the location set on the map
(`{lat, lng, source: "map", time}`, as in [Device
location](device-location.md)) or null. Older records have no
`profileId` or `location`. A `config` whose `version` is newer than the
app's (`PresenceConfig.version`, 1) isn't applied: the app would drop what
it doesn't know, so the local settings stay and go up over it.

### Not on S3: copies

Who holds a copy of each event ([Event copies](event-copies.md)) is
**not** written into the event record: it travels only as live sync's
`copied` acks (`{v, kind: "copied", deviceId, identityId, sentAt,
eventIds}`, at most 1 KB) and is kept on each device (the local
`settings` store's `copies` record). Writing it into the record would
change the record's ETag with each ack, and devices would upload and
fetch it back and forth.

## On S3

All under the user's Cognito identity ID (`us-east-1:<uuid>`), in the
user-data bucket. **JSON and media are in separate trees**, so a query over
`events/` or `clips/` never meets a video:

```
<identityId>/
  events/year=2026/day=275/<eventId>.json      JSON: event records
  clips/year=2026/day=275/<clipId>.json        JSON: clip records
  devices/<deviceId>/settings.json             JSON: each device's settings
  media/<clipId>.webm (or .mp4)                the recording
  media/<clipId>.jpg                           the thumbnail
  media/<clipId>/frames/<frameId>.jpg          the frames tags were made on
```

- **Partitions** are Hive-style, by the UTC day of the year (`day=001` to
  `day=366`, zero-padded), so the keys sort by date and a query on a few
  days reads only those folders.
- **Content types:** `application/json`, `video/webm;codecs=…` or
  `video/mp4`, `image/jpeg`. Objects are stored in Intelligent-Tiering and
  expire after 90 days ([Production deploy](deploy.md)).
- **Before 2026-10-02** clip records were `clips/<clipId>.json`, next to
  `clips/<clipId>.webm`, `.jpg` and `clips/<clipId>/frames/`. The buckets
  were emptied then; a device that uploaded something under an old key
  doesn't upload it again under the new one.

## Querying

- **Athena** (Presto SQL straight on S3) reads the JSON trees with the
  OpenX JSON SerDe and **partition projection**, so no crawler or
  `MSCK REPAIR` is needed. The identity is the first folder and isn't in
  `key=value` form, so it's an `injected` partition: each query names the
  user(s). A table over the events:

  ```sql
  CREATE EXTERNAL TABLE presence_events (
    id string, type string, title string, detail string, `time` bigint,
    cameraId string, deviceId string, userId string, profileId string,
    location struct<lat:double, lng:double, accuracy:double, source:string, `time`:bigint>,
    os string, clipId string, clipState string, `trigger` string,
    annotations array<struct<id:string, name:string, x:double, y:double,
      frameId:string, frameMs:bigint, source:string, confidence:double>>,
    objectTags array<struct<label:string, ms:bigint, score:double>>,
    clipEventId string, annotationId string, subjectName string, confidence double
  )
  PARTITIONED BY (identity string, year int, day int)
  ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
  LOCATION 's3://<user-data bucket>/'
  TBLPROPERTIES (
    'projection.enabled' = 'true',
    'projection.identity.type' = 'injected',
    'projection.year.type' = 'integer', 'projection.year.range' = '2026,2100',
    'projection.day.type' = 'integer', 'projection.day.range' = '1,366',
    'projection.day.digits' = '3',
    'storage.location.template' =
      's3://<user-data bucket>/${identity}/events/year=${year}/day=${day}/'
  );

  -- This week's clips with a bicycle, and who was tagged on them.
  SELECT from_unixtime(e."time" / 1000) AS at, e.clipId,
         transform(e.annotations, a -> a.name) AS people
  FROM presence_events e
  WHERE e.identity = 'us-east-1:<uuid>' AND e.year = 2026 AND e.day >= 269
    AND e.type = 'clip_requested'
    AND any_match(e.objectTags, o -> o.label = 'bicycle');
  ```

  A `presence_clips` table is the same over `clips/year=…/day=…/`, with the
  clip record's fields. Across all users, an `enum` projection of the
  identity IDs, or a Glue crawler over the JSON trees, does instead.
- **S3 Select** (SQL on one object) reads these files too (JSON, `LINES`
  or `DOCUMENT`), but AWS closed it to new customers in July 2024: Athena
  is the way.

## Verified

- `cloud_sync_test.dart`: uploads go to `media/` and the clip record to
  `clips/year=1970/day=001/c1.json`, without its thumbnail; a fetch reads
  the record from its event's day and the recording and thumbnail from
  `media/`; tagged frames go to `media/<clipId>/frames/`; what was uploaded
  under the old keys isn't uploaded again; the two-week window reads the
  clip records of the events it keeps.
- `persistence_test.dart`: a clip recorded in the app goes up as
  `media/<id>.webm`, `media/<id>.jpg` and a day-partitioned record, and a
  clip from the cloud comes back from the new keys.
- 271 Flutter tests pass.

## Known limitations

- **The Athena table hasn't been created or run yet** (the buckets are
  empty): the DDL above is a starting point, to check against real data.
- **Web video size and bit rate are the browser's choice**, so clips from
  different browsers and cameras vary.
- **Times are epoch milliseconds**, not ISO strings: queries convert them
  (`from_unixtime(time / 1000)`).
- Event records of different types share one table: fields a type doesn't
  have read as null.
