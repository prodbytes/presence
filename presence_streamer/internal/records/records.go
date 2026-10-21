// Package records writes the JSON records and object keys the app writes
// (see specs/data-formats.md), so an event the streamer stores is read
// like one from a phone.
package records

import (
	"encoding/json"
	"fmt"
	"time"
)

// Location is where the device is (`{lat, lng, accuracy, source, time}`).
type Location struct {
	Lat      float64  `json:"lat"`
	Lng      float64  `json:"lng"`
	Accuracy *float64 `json:"accuracy"`
	Source   string   `json:"source"`
	Time     int64    `json:"time"`
}

// ObjectTag is what recognition saw: a label, when (ms into the clip) and
// its best score.
type ObjectTag struct {
	Label string  `json:"label"`
	Ms    int64   `json:"ms"`
	Score float64 `json:"score"`
}

// Event is a clip event (`clip_requested`), as the app's
// ClipRequested.toRecord.
type Event struct {
	ID         string      `json:"id"`
	Type       string      `json:"type"`
	Title      string      `json:"title"`
	Detail     string      `json:"detail"`
	Time       int64       `json:"time"`
	CameraID   string      `json:"cameraId"`
	DeviceID   string      `json:"deviceId"`
	UserID     string      `json:"userId"`
	ProfileID  string      `json:"profileId"`
	Location   *Location   `json:"location"`
	OS         string      `json:"os"`
	ClipID     string      `json:"clipId"`
	ClipState  string      `json:"clipState"`
	Trigger    string      `json:"trigger"`
	ObjectTags []ObjectTag `json:"objectTags"`
	// CameraName is the camera's own name ("Garden"), for a camera the
	// streamer fetches clips from (Blink, GoPro, Reolink), each its own
	// device: the app shows it beside the device ("Garden | <device>").
	// Absent for the Pi's own camera.
	CameraName string `json:"cameraName,omitempty"`
	// StoredAt is when the streamer stored the event (ms since the
	// epoch): a camera's clip may be fetched long after it was recorded
	// (Time), and the app recognizes synced clips stored lately.
	StoredAt int64 `json:"storedAt,omitempty"`
}

// MediaRef is a recording's reference in a clip record.
type MediaRef struct {
	MediaID  string `json:"mediaId"`
	StartMs  int64  `json:"startMs"`
	EndMs    int64  `json:"endMs"`
	MimeType string `json:"mimeType"`
}

// Clip is a clip record, as the app's.
type Clip struct {
	ID          string   `json:"id"`
	EventID     string   `json:"eventId"`
	CameraID    string   `json:"cameraId"`
	CameraLabel string   `json:"cameraLabel"`
	RequestedAt int64    `json:"requestedAt"`
	BeforeMs    int64    `json:"beforeMs"`
	AfterMs     int64    `json:"afterMs"`
	Supported   bool     `json:"supported"`
	State       string   `json:"state"`
	Full        MediaRef `json:"full"`
}

// Settings is the device's settings record: the app reads its media key
// from it, to open what it uploads.
type Settings struct {
	DeviceID  string         `json:"deviceId"`
	ProfileID string         `json:"profileId"`
	UpdatedAt int64          `json:"updatedAt"`
	Config    map[string]any `json:"config"`
	Location  *Location      `json:"location"`
	MediaKey  string         `json:"mediaKey"`
}

// Camera is what an event says of the camera that recorded it. OS is the
// device's operating system on the event: "Linux" when empty (the Pi's
// own camera), "Blink" for a Blink camera, "GoPro" for a GoPro, "Reolink" for a Reolink.
// Name is a fetched camera's own name (the event's cameraName), empty for
// the Pi's own camera.
type Camera struct {
	ID    string
	Label string
	OS    string
	Name  string
}

// Chunk is a recorded chunk with a subject in it, to be stored as a clip.
type Chunk struct {
	Start    time.Time
	Duration time.Duration
	Tags     []ObjectTag
	// StoredAt is when it's stored (the event's storedAt); zero: not said.
	StoredAt time.Time
}

// ClipOf makes the event and clip record of a chunk, as a phone makes for
// a motion clip: the chunk is the whole clip (nothing before, all after).
func ClipOf(chunk Chunk, eventID, clipID string, camera Camera, deviceID, userID, profileID string, location *Location) (Event, Clip) {
	at := chunk.Start.UnixMilli()
	length := chunk.Duration.Milliseconds()
	tags := chunk.Tags
	if tags == nil {
		tags = []ObjectTag{}
	}
	os := camera.OS
	if os == "" {
		os = "Linux"
	}
	event := Event{
		ID:         eventID,
		Type:       "clip_requested",
		Title:      "Motion detected",
		Detail:     camera.Label,
		Time:       at,
		CameraID:   camera.ID,
		DeviceID:   deviceID,
		UserID:     userID,
		ProfileID:  profileID,
		Location:   location,
		OS:         os,
		ClipID:     clipID,
		ClipState:  "complete",
		Trigger:    "motion",
		ObjectTags: tags,
		CameraName: camera.Name,
	}
	if !chunk.StoredAt.IsZero() {
		event.StoredAt = chunk.StoredAt.UnixMilli()
	}
	clip := Clip{
		ID:          clipID,
		EventID:     eventID,
		CameraID:    camera.ID,
		CameraLabel: camera.Label,
		RequestedAt: at,
		BeforeMs:    0,
		AfterMs:     length,
		Supported:   true,
		State:       "complete",
		Full: MediaRef{
			MediaID:  clipID + "-full",
			StartMs:  0,
			EndMs:    length,
			MimeType: "video/mp4",
		},
	}
	return event, clip
}

// JSON is a record as uploaded: compact, on one line.
func JSON(record any) []byte {
	b, err := json.Marshal(record)
	if err != nil {
		panic(err)
	}
	return b
}

// dayPrefix is root's partition for t's UTC day: `events/year=2026/day=269/`.
func dayPrefix(root string, t time.Time) string {
	t = t.UTC()
	return fmt.Sprintf("%s/year=%d/day=%03d/", root, t.Year(), t.YearDay())
}

// Object keys under the profile's identity folder.

func EventKey(e Event) string {
	return dayPrefix("events", time.UnixMilli(e.Time)) + e.ID + ".json"
}

func ClipKey(c Clip) string {
	return dayPrefix("clips", time.UnixMilli(c.RequestedAt)) + c.ID + ".json"
}

func RecordingKey(clipID string) string { return "media/" + clipID + ".mp4" }

func ThumbnailKey(clipID string) string { return "media/" + clipID + ".jpg" }

func SettingsKey(deviceID string) string { return "devices/" + deviceID + "/settings.json" }

// JobKey is where a chunk's job for the cloud detector goes, after the
// chunk: its upload is what S3 notifies the detector of (presence_ingest).
func JobKey(deviceID, chunkID string) string {
	return "ingest/" + deviceID + "/" + chunkID + ".ingest.json"
}

// Job is a chunk's job for the cloud detector: the clip record and event it
// stores when the chunk has a subject, but for the object tags it adds.
type Job struct {
	V     int   `json:"v"`
	Event Event `json:"event"`
	Clip  Clip  `json:"clip"`
	// KeepAll stores the chunk with no one in it too (a fetched camera's
	// clip: stream.Streamer.KeepAll), tagged with what's found.
	KeepAll bool `json:"keepAll,omitempty"`
}

// IngestKey is where a chunk lands, sealed, before it's searched: a
// prefix of the profile's folder that the app never lists.
func IngestKey(deviceID, chunkID string) string {
	return "ingest/" + deviceID + "/" + chunkID + ".mp4"
}
