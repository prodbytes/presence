package stream

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/detect"
	"github.com/prodbytes/presence/presence_streamer/internal/records"
	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// bucket is a fake profile folder: objects by key, the operations done,
// and an operation to fail once.
type bucket struct {
	objects map[string][]byte
	ops     []string
	failOn  string
}

func (b *bucket) fail(op string) error {
	if b.failOn != "" && strings.HasPrefix(op, b.failOn) {
		b.failOn = ""
		return errors.New("network down")
	}
	b.ops = append(b.ops, op)
	return nil
}

func (b *bucket) Put(_ context.Context, path, key, contentType string) error {
	if err := b.fail("put " + key); err != nil {
		return err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	b.objects[key] = data
	return nil
}

func (b *bucket) Move(_ context.Context, from, to string) error {
	if err := b.fail("move " + from + " " + to); err != nil {
		return err
	}
	data, ok := b.objects[from]
	if !ok {
		return fmt.Errorf("no %s", from)
	}
	b.objects[to] = data
	delete(b.objects, from)
	return nil
}

func (b *bucket) Delete(_ context.Context, key string) error {
	if err := b.fail("delete " + key); err != nil {
		return err
	}
	delete(b.objects, key)
	return nil
}

// searcher finds a person in chunks whose frames say so, and writes a
// thumbnail.
type searcher struct{}

func (searcher) Search(frames []detect.Frame, thumbnail string) (detect.Result, error) {
	if len(frames) > 0 && strings.Contains(frames[0].Path, "person") {
		os.WriteFile(thumbnail, []byte("jpeg"), 0o600)
		return detect.Result{
			Objects: []detect.Object{{Label: "bicycle", Ms: 2000, Score: 0.7}, {Label: "human", Ms: 1000, Score: 0.55}, {Label: "cup", Ms: 0, Score: 0.45}},
			Subject: &detect.Object{Label: "human", Ms: 1000, Score: 0.55},
		}, nil
	}
	return detect.Result{}, nil
}

func key() []byte { return bytes.Repeat([]byte{7}, 32) }

func streamer(t *testing.T, b *bucket, kind string) (*Streamer, string) {
	spool := t.TempDir()
	return &Streamer{
		Spool: spool, Store: b, Searcher: searcher{},
		Keyframes: func(_ context.Context, chunk, dir string) ([]detect.Frame, error) {
			return []detect.Frame{{Path: filepath.Join(dir, kind+".jpg")}}, nil
		},
		Duration: func(_ context.Context, chunk string) (time.Duration, error) {
			data, _ := os.ReadFile(chunk)
			switch string(data) {
			case "broken":
				return 0, fmt.Errorf("%w: moov atom not found", detect.ErrBroken)
			case "cancelled":
				return 0, context.Canceled
			}
			return 30 * time.Second, nil
		},
		Key: key(), DeviceID: "able_adept_gadget", ProfileID: "automatic_paranoid_axolotl",
		UserID:      func() string { return "42" },
		Camera:      records.Camera{ID: "libcamera", Label: "Raspberry Pi camera"},
		ObjectScore: 0.6,
		Logf:        t.Logf,
	}, spool
}

func chunk(t *testing.T, spool, content string) string {
	path := filepath.Join(spool, "rec-20260926T120000.mp4")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func open(t *testing.T, sealed []byte) string {
	var out bytes.Buffer
	if err := seal.Open(&out, bytes.NewReader(sealed), key()); err != nil {
		t.Fatalf("doesn't open: %v", err)
	}
	return out.String()
}

func leftovers(spool string) []string {
	names, _ := filepath.Glob(filepath.Join(spool, "*"))
	return names
}

func TestNoOneThereIsDeleted(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "empty")
	c := chunk(t, spool, "video")
	if err := s.Process(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if len(b.ops) != 2 || !strings.HasPrefix(b.ops[0], "put ingest/able_adept_gadget/") || !strings.HasPrefix(b.ops[1], "delete ingest/") {
		t.Fatalf("ops %v", b.ops)
	}
	if len(b.objects) != 0 || len(leftovers(spool)) != 0 {
		t.Fatalf("left %v in the bucket, %v here", b.objects, leftovers(spool))
	}
}

func TestSubjectIsStoredAsAPhoneWould(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "person")
	var stored []records.Event
	s.Stored = func(e records.Event) { stored = append(stored, e) }
	c := chunk(t, spool, "video")
	if err := s.Process(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if len(stored) != 1 {
		t.Fatalf("stored %v", stored)
	}
	e := stored[0]
	clipID := e.ClipID
	want := []string{
		"put ingest/able_adept_gadget/" + clipID + ".mp4",
		"put media/" + clipID + ".jpg",
		"move ingest/able_adept_gadget/" + clipID + ".mp4 media/" + clipID + ".mp4",
		"put clips/year=2026/day=269/" + clipID + ".json",
		"put events/year=2026/day=269/" + e.ID + ".json",
	}
	if strings.Join(b.ops, "\n") != strings.Join(want, "\n") {
		t.Fatalf("ops:\n%s\nwant:\n%s", strings.Join(b.ops, "\n"), strings.Join(want, "\n"))
	}
	if got := open(t, b.objects["media/"+clipID+".mp4"]); got != "video" {
		t.Fatalf("recording opens to %q", got)
	}
	if got := open(t, b.objects["media/"+clipID+".jpg"]); got != "jpeg" {
		t.Fatalf("thumbnail opens to %q", got)
	}
	var event map[string]any
	json.Unmarshal(b.objects["events/year=2026/day=269/"+e.ID+".json"], &event)
	if event["time"] != float64(time.Date(2026, 9, 26, 12, 0, 0, 0, time.UTC).UnixMilli()) ||
		event["userId"] != "42" || event["trigger"] != "motion" {
		t.Fatalf("event %v", event)
	}
	// The bicycle (0.7) passes the object score, the cup (0.45) doesn't;
	// the subject (0.55) is tagged anyway.
	tags, _ := json.Marshal(event["objectTags"])
	if string(tags) != `[{"label":"bicycle","ms":2000,"score":0.7},{"label":"human","ms":1000,"score":0.55}]` {
		t.Fatalf("object tags %s", tags)
	}
	var clip records.Clip
	json.Unmarshal(b.objects["clips/year=2026/day=269/"+clipID+".json"], &clip)
	if clip.EventID != e.ID || clip.Full.EndMs != 30000 {
		t.Fatalf("clip %+v", clip)
	}
	if len(leftovers(spool)) != 0 {
		t.Fatalf("left %v", leftovers(spool))
	}
}

func TestCarriesOnAfterAFailure(t *testing.T) {
	for _, step := range []string{"put ingest/", "put media/", "put clips/", "put events/"} {
		t.Run(step, func(t *testing.T) {
			b := &bucket{objects: map[string][]byte{}, failOn: step}
			s, spool := streamer(t, b, "person")
			c := chunk(t, spool, "video")
			if err := s.Process(context.Background(), c); err == nil {
				t.Fatal("no error")
			}
			if err := s.Process(context.Background(), c); err != nil {
				t.Fatal(err)
			}
			seen := map[string]int{}
			for _, op := range b.ops {
				seen[op]++
				if seen[op] > 1 && !strings.HasPrefix(op, "put events/") && !strings.HasPrefix(op, "put clips/") {
					t.Errorf("%s done twice", op)
				}
			}
			if len(b.ops) != 5 {
				t.Errorf("ops %v", b.ops)
			}
			if len(leftovers(spool)) != 0 {
				t.Errorf("left %v", leftovers(spool))
			}
		})
	}
}

// A move that fails (the recording moved already, before a crash kept it
// from being noted) uploads the sealed copy instead.
func TestAFailedMoveUploadsTheSealedCopy(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}, failOn: "move "}
	s, spool := streamer(t, b, "person")
	if err := s.Process(context.Background(), chunk(t, spool, "video")); err != nil {
		t.Fatal(err)
	}
	var recording []byte
	for key, data := range b.objects {
		if strings.HasPrefix(key, "media/") && strings.HasSuffix(key, ".mp4") {
			recording = data
		}
		if strings.HasPrefix(key, "ingest/") {
			t.Errorf("left in ingest: %s", key)
		}
	}
	if open(t, recording) != "video" {
		t.Fatal("no recording in media/")
	}
	if len(leftovers(spool)) != 0 {
		t.Fatalf("left %v", leftovers(spool))
	}
}

type failing struct{ err error }

func (f failing) Search([]detect.Frame, string) (detect.Result, error) { return detect.Result{}, f.err }

func TestASearchThatKeepsFailingIsGivenUp(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "person")
	s.Searcher = failing{errors.New("the detector failed: bad frame")}
	c := chunk(t, spool, "video")
	for i := 1; i < maxFailures; i++ {
		if err := s.Process(context.Background(), c); err == nil {
			t.Fatalf("try %d: no error", i)
		}
	}
	if err := s.Process(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if len(leftovers(spool)) != 0 || len(b.objects) != 0 {
		t.Fatalf("left %v here, %v in the bucket", leftovers(spool), b.objects)
	}
}

func TestADetectorThatIsDownGivesUpNothing(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "person")
	s.Searcher = failing{fmt.Errorf("%w: no OpenCV", detect.ErrUnavailable)}
	c := chunk(t, spool, "video")
	for range maxFailures + 2 {
		if err := s.Process(context.Background(), c); err == nil {
			t.Fatal("no error")
		}
	}
	if _, err := os.Stat(c); err != nil {
		t.Fatal("the chunk was deleted")
	}
}

func TestACancelledProbeKeepsTheChunk(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "person")
	c := chunk(t, spool, "cancelled")
	if err := s.Process(context.Background(), c); err == nil {
		t.Fatal("no error")
	}
	if _, err := os.Stat(c); err != nil {
		t.Fatal("the chunk was deleted")
	}
}

func TestBrokenChunkIsDeleted(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "person")
	if err := s.Process(context.Background(), chunk(t, spool, "broken")); err != nil {
		t.Fatal(err)
	}
	if len(b.ops) != 0 || len(leftovers(spool)) != 0 {
		t.Fatalf("ops %v, left %v", b.ops, leftovers(spool))
	}
}

func TestTrim(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "empty")
	var chunks []string
	for i := range 4 {
		c := filepath.Join(spool, fmt.Sprintf("rec-20260926T12000%d.mp4", i))
		os.WriteFile(c, make([]byte, 1000), 0o600)
		chunks = append(chunks, c)
	}
	s.MaxSpool = 2500
	s.Trim(chunks)
	if left := leftovers(spool); len(left) != 2 || filepath.Base(left[0]) != "rec-20260926T120002.mp4" {
		t.Fatalf("left %v", left)
	}
}

func TestSettingsCarryTheKey(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, _ := streamer(t, b, "empty")
	if err := s.Settings(context.Background(), time.UnixMilli(5)); err != nil {
		t.Fatal(err)
	}
	var settings map[string]any
	json.Unmarshal(b.objects["devices/able_adept_gadget/settings.json"], &settings)
	if settings["deviceId"] != "able_adept_gadget" || settings["mediaKey"] != base64.StdEncoding.EncodeToString(key()) ||
		settings["config"].(map[string]any)["version"] != 1.0 || settings["updatedAt"] != 5.0 {
		t.Fatalf("settings %v", settings)
	}
}
