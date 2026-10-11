package records

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

func TestClipOf(t *testing.T) {
	start := time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC)
	event, clip := ClipOf(Chunk{
		Start:    start,
		Duration: 30 * time.Second,
		Tags:     []ObjectTag{{Label: "human", Ms: 4000, Score: 0.91}},
	}, "e1", "c1", Camera{ID: "libcamera", Label: "Raspberry Pi camera"},
		"able_adept_gadget", "1234", "automatic_paranoid_axolotl", nil)

	var got map[string]any
	if err := json.Unmarshal(JSON(event), &got); err != nil {
		t.Fatal(err)
	}
	for k, v := range map[string]any{
		"id": "e1", "type": "clip_requested", "title": "Motion detected",
		"detail": "Raspberry Pi camera", "time": float64(start.UnixMilli()),
		"cameraId": "libcamera", "deviceId": "able_adept_gadget", "userId": "1234",
		"profileId": "automatic_paranoid_axolotl", "os": "Linux", "clipId": "c1",
		"clipState": "complete", "trigger": "motion", "location": nil,
	} {
		if got[k] != v {
			t.Errorf("event %s = %v, want %v", k, got[k], v)
		}
	}
	tags := got["objectTags"].([]any)
	if tag := tags[0].(map[string]any); tag["label"] != "human" || tag["ms"] != 4000.0 || tag["score"] != 0.91 {
		t.Errorf("object tag %v", tag)
	}

	if clip.RequestedAt != event.Time || clip.EventID != "e1" || clip.AfterMs != 30000 ||
		clip.Full != (MediaRef{MediaID: "c1-full", StartMs: 0, EndMs: 30000, MimeType: "video/mp4"}) ||
		clip.State != "complete" {
		t.Errorf("clip %+v", clip)
	}
	if strings.Contains(string(JSON(clip)), "\n") {
		t.Error("records must be on one line")
	}
}

func TestKeys(t *testing.T) {
	at := time.Date(2026, 9, 26, 23, 59, 0, 0, time.UTC)
	event := Event{ID: "e1", Time: at.UnixMilli()}
	if got := EventKey(event); got != "events/year=2026/day=269/e1.json" {
		t.Errorf("event key %s", got)
	}
	if got := ClipKey(Clip{ID: "c1", RequestedAt: time.Date(2024, 12, 31, 0, 0, 0, 0, time.UTC).UnixMilli()}); got != "clips/year=2024/day=366/c1.json" {
		t.Errorf("clip key %s", got)
	}
	if got := ClipKey(Clip{ID: "c1", RequestedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC).UnixMilli()}); got != "clips/year=2026/day=001/c1.json" {
		t.Errorf("clip key %s", got)
	}
	if RecordingKey("c1") != "media/c1.mp4" || ThumbnailKey("c1") != "media/c1.jpg" ||
		SettingsKey("d") != "devices/d/settings.json" || IngestKey("d", "x") != "ingest/d/x.mp4" {
		t.Error("media, settings or ingest key")
	}
}

// The job fixture presence_ingest's tests check with the cloud detector
// (test_app.py); UPDATE_FIXTURE=1 writes it again.
func TestJobFixture(t *testing.T) {
	event, clip := ClipOf(Chunk{Start: time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC), Duration: 30 * time.Second},
		"hmnhfi8000-0aaaaaa", "hmnhfi8000-12ifwo6", Camera{ID: "libcamera", Label: "Raspberry Pi camera"},
		"able_adept_gadget", "42", "automatic_paranoid_axolotl", nil)
	got := JSON(Job{V: 1, Event: event, Clip: clip})
	const fixture = "../../testdata/job-fixture.json"
	if os.Getenv("UPDATE_FIXTURE") == "1" {
		os.WriteFile(fixture, got, 0o644)
	}
	if want, err := os.ReadFile(fixture); err != nil || string(want) != string(got) {
		t.Fatalf("the job isn't the committed fixture (%v)", err)
	}
}
