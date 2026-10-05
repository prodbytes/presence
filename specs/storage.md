# Storage

All app data is saved in the browser's **IndexedDB**, so it survives a page
refresh. It's accessed through [`idb_shim`](https://pub.dev/packages/idb_shim)
(`EventStore` in
[lib/storage/event_store.dart](../presence_app/lib/storage/event_store.dart),
with the mapping in
[lib/storage/persistence.dart](../presence_app/lib/storage/persistence.dart)).

On **web**, all app data is in IndexedDB, as described below. On
**Android**, the same stores live in a sembast database on disk, and
recordings are files instead of `media` rows (see [Android](android.md)).
Everything goes through `EventStore` and `MediaStore`.

**Why IndexedDB (not drift/SQLite or `localStorage`):**
- `localStorage` holds only ~5 MB of strings. One 30 s clip is ~10 MB per
  camera.
- IndexedDB stores binary recordings directly, and can save a clip's record
  and delete its media in one transaction.
- It needs no code generation, WASM or special server headers.
- drift remains the upgrade path if SQL queries or mobile clip storage are
  needed; everything goes through `EventStore`, so it can be swapped out.

**Database `presence`, version 2** (version 2 added `synced`):

| Store | Key | Holds |
|-------|-----|-------|
| `cameras` | `id` (the browser's media device ID for the camera) | label, last seen |
| `events` | `id`, with an index on `time` | type, title, detail, time, camera ID, device ID, user ID, and for clips the clip ID and `clipState` (`partial` / `complete`) |
| `clips` | `id`, with an index on `eventId` | event ID, camera ID and label, before/after lengths, state, thumbnail (JPEG bytes), and a media reference for the before part or the full clip (media ID, window start/end, format) |
| `media` | media ID (`<clipId>-past` or `<clipId>-full`) | recording bytes |
| `settings` | name (`config`, `device`, `location`, `consent`) | `config`: the whole `PresenceConfig` as versioned JSON, with when it last changed (`updatedAt`) and the profile it was last synced with (`profileId`); also kept in S3 per profile and device, with the location set on the map, see [Configuration](configuration.md) (the older flat `clip` record is read once, on upgrade); `device`: this device's ID ([Devices, users and places](devices-users-places.md)); `location`: where it is ([Device location](device-location.md)); `consent`: its recording consent, with a verification hash ([Recording consent](consent.md)) |
| `synced` | S3 object key | a fingerprint of what was uploaded there, and under `etag:<key>` an event's ETag as last uploaded or downloaded ([cloud sync](cloud-sync.md)) |

**References:** each event has a stable `id`, and events from a camera carry
its `cameraId`. A `ClipRequested` event references its clip (`clipId`). The
clip references its event (`eventId`), its camera (`cameraId`) and its media.
Camera IDs are the browser's media device IDs, which stay stable for the
site until its data is cleared. They aren't the app's device ID
(`deviceId` on events), which names the install.

**How a clip is saved:**
1. When Clip is pressed, the event and a clip record (state `recording`,
   with the thumbnail) are saved.
2. The before part is saved as soon as it exists, so it survives a refresh
   during the after part.
3. When the full clip exists, it's saved, and the before-only file is
   deleted in the same transaction (the full clip contains it). The clip's
   state becomes `complete`, and the event record is updated to
   `clipState: complete`.
4. If saving fails (for example, storage is full), the clip card says "not
   saved" with the reason. The clip still plays for the rest of the session.

**On launch**, events are restored newest first, below the new launch's
"Application started" event. Stored clips are playable. Their recordings load
from IndexedDB the first time they're played, not all at startup. A clip
whose after part was cut short by a refresh keeps its before part and says
so. Clip settings are restored too.

**Persistence and quota:** the app asks the browser for persistent storage
(`navigator.storage.persist()`), so saved clips aren't evicted when disk space
runs low. Browsers may grant or decline this silently. Events older than
the History setting (two weeks by default) are deleted with their clips
and recordings, at load and every 3 hours: see
[Event retention](event-retention.md).

## Known limitations

- Storage still holds roughly 10 MB per camera per clip, for as long as
  the History setting keeps it.
- The `synced` store keeps the keys of uploaded events after retention
  deletes them (a few dozen bytes each).
- Persistence has been verified with unit and widget tests against an
  in-memory IndexedDB, but not yet in a real browser.
