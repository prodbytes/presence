package stream

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/detect"
	"github.com/prodbytes/presence/presence_streamer/internal/records"
	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// bucket is a fake profile folder: objects by key, the operations done,
// an operation to fail once, and one whose copy lands corrupted once (as
// with rclone, it then fails verification and keeps no copy).
type bucket struct {
	objects   map[string][]byte
	ops       []string
	failOn    string
	corruptOn string
}

// verify is rclone's check after a copy: the same size and MD5, or it
// fails and the copy's deleted.
func (b *bucket) verify(op string, sent []byte) ([]byte, error) {
	got := sent
	if b.corruptOn != "" && strings.Contains(op, b.corruptOn) {
		b.corruptOn = ""
		got = append([]byte("x"), sent[1:]...)
	}
	if len(got) != len(sent) || md5.Sum(got) != md5.Sum(sent) {
		b.ops = b.ops[:len(b.ops)-1]
		return nil, errors.New("corrupted on transfer: md5 hash differ")
	}
	return got, nil
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
	if data, err = b.verify("put "+key, data); err != nil {
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
	data, err := b.verify("move "+from, data)
	if err != nil {
		return err
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

// Each stored event goes to live sync once it's in the bucket: the very
// JSON uploaded, its key and its MD5 (the object's ETag); none when the
// event's upload fails, and once when it's tried again.
func TestStoredEventsArePublished(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}, failOn: "put events/"}
	s, spool := streamer(t, b, "person")
	type published struct {
		body      []byte
		key, etag string
	}
	var got []published
	s.Publish = func(body []byte, key, etag string) { got = append(got, published{body, key, etag}) }
	c := chunk(t, spool, "video")
	if err := s.Process(context.Background(), c); err == nil {
		t.Fatal("no error")
	}
	if len(got) != 0 {
		t.Fatalf("published before it was stored: %v", got)
	}
	if err := s.Process(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("published %d times", len(got))
	}
	uploaded, ok := b.objects[got[0].key]
	if !ok || !strings.HasPrefix(got[0].key, "events/year=2026/day=269/") || !bytes.Equal(uploaded, got[0].body) {
		t.Fatalf("published %s at %s, uploaded %s", got[0].body, got[0].key, uploaded)
	}
	if sum := md5.Sum(uploaded); got[0].etag != fmt.Sprintf("%x", sum) {
		t.Fatalf("etag %s", got[0].etag)
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

// On a Pi with too little memory, the chunk goes up with its job for the
// cloud detector, once the device's key is up, and is deleted here.
func TestCloudDetection(t *testing.T) {
	b := &bucket{objects: map[string][]byte{}}
	s, spool := streamer(t, b, "person")
	s.Cloud = true
	s.Searcher = failing{errors.New("searched here")}
	c := chunk(t, spool, "video")
	if err := s.Process(context.Background(), c); !errors.Is(err, errSettingsPending) {
		t.Fatalf("before the settings: %v", err)
	}
	if err := s.Settings(context.Background(), time.UnixMilli(5)); err != nil {
		t.Fatal(err)
	}
	if err := s.Process(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	if len(b.ops) != 3 || !strings.HasPrefix(b.ops[1], "put ingest/able_adept_gadget/") || !strings.HasSuffix(b.ops[1], ".mp4") ||
		!strings.HasSuffix(b.ops[2], ".ingest.json") {
		t.Fatalf("ops %v", b.ops)
	}
	var job struct {
		V     int            `json:"v"`
		Event map[string]any `json:"event"`
		Clip  map[string]any `json:"clip"`
	}
	jobKey := strings.TrimPrefix(b.ops[2], "put ")
	if err := json.Unmarshal(b.objects[jobKey], &job); err != nil {
		t.Fatal(err)
	}
	clipID := job.Clip["id"].(string)
	if job.V != 1 || job.Event["clipId"] != clipID || job.Clip["eventId"] != job.Event["id"] ||
		job.Event["deviceId"] != "able_adept_gadget" || job.Event["type"] != "clip_requested" ||
		jobKey != "ingest/able_adept_gadget/"+clipID+".ingest.json" {
		t.Fatalf("job %s: %+v", jobKey, job)
	}
	if got := open(t, b.objects["ingest/able_adept_gadget/"+clipID+".mp4"]); got != "video" {
		t.Fatalf("the chunk opens to %q", got)
	}
	if len(leftovers(spool)) != 0 {
		t.Fatalf("left %v", leftovers(spool))
	}
}

// A chunk without motion is deleted here, before any upload; one with
// motion goes on.
func TestMotion(t *testing.T) {
	for _, c := range []struct {
		motion float64
		ops    int
	}{{2.5, 0}, {5, 0}, {5.1, 5}} {
		b := &bucket{objects: map[string][]byte{}}
		s, spool := streamer(t, b, "person")
		s.MotionMin = 5
		s.Motion = func(context.Context, string) (float64, error) { return c.motion, nil }
		if err := s.Process(context.Background(), chunk(t, spool, "video")); err != nil {
			t.Fatal(err)
		}
		if len(b.ops) != c.ops || len(leftovers(spool)) != 0 {
			t.Errorf("motion %v%%: ops %v, left %v", c.motion, b.ops, leftovers(spool))
		}
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

// names is what's left in the spool, by suffix after the chunk's name.
func names(spool, c string) map[string]bool {
	out := map[string]bool{}
	for _, p := range leftovers(spool) {
		out[strings.TrimPrefix(p, c)] = true
	}
	return out
}

// A copy that lands corrupted fails verification: it's a failed upload.
// What it was for stays here and is tried again; what's verified already
// is deleted here at once.
func TestLocalFilesGoOnlyOnceVerified(t *testing.T) {
	for _, c := range []struct {
		step       string
		kept, gone []string
	}{
		{"put ingest/", []string{"", ".json", ".sealed"}, nil},
		{"put media/", []string{"", ".json", ".sealed", ".jpg", ".jpg.sealed"}, nil},
		// The move fails: the sealed copy goes up instead, verified.
		{"move ", nil, nil},
		{"put clips/", []string{"", ".json"}, []string{".sealed", ".jpg", ".jpg.sealed"}},
		{"put events/", []string{"", ".json"}, []string{".sealed", ".jpg", ".jpg.sealed", ".clip.json"}},
	} {
		t.Run(c.step, func(t *testing.T) {
			b := &bucket{objects: map[string][]byte{}, corruptOn: c.step}
			s, spool := streamer(t, b, "person")
			ch := chunk(t, spool, "video")
			err := s.Process(context.Background(), ch)
			if c.kept == nil {
				if err != nil {
					t.Fatal(err)
				}
			} else {
				if err == nil {
					t.Fatal("no error")
				}
				left := names(spool, ch)
				for _, k := range c.kept {
					if !left[k] {
						t.Errorf("%q deleted before it was verified (left %v)", k, left)
					}
				}
				for _, g := range c.gone {
					if left[g] {
						t.Errorf("%q kept after it was verified", g)
					}
				}
				if err := s.Process(context.Background(), ch); err != nil {
					t.Fatal(err)
				}
			}
			if len(leftovers(spool)) != 0 {
				t.Fatalf("left %v", leftovers(spool))
			}
			var media int
			for key, data := range b.objects {
				if strings.HasPrefix(key, "ingest/") {
					t.Errorf("left in ingest: %s", key)
				}
				if strings.HasPrefix(key, "media/") {
					media++
					if strings.HasSuffix(key, ".mp4") && open(t, data) != "video" {
						t.Errorf("%s doesn't open to the chunk", key)
					}
				}
			}
			if media != 2 {
				t.Fatalf("media: %v", b.objects)
			}
		})
	}
}

// In the cloud's mode, a chunk or job whose upload fails verification
// stays, and goes up at the next try; once verified, it's deleted here.
func TestCloudChunkGoesOnlyOnceVerified(t *testing.T) {
	// The chunk; the job, after the chunk's verified.
	for _, step := range []string{".mp4", ".ingest.json"} {
		t.Run(step, func(t *testing.T) {
			b := &bucket{objects: map[string][]byte{}}
			s, spool := streamer(t, b, "person")
			s.Cloud = true
			if err := s.Settings(context.Background(), time.UnixMilli(5)); err != nil {
				t.Fatal(err)
			}
			b.ops, b.corruptOn = nil, step
			ch := chunk(t, spool, "video")
			if err := s.Process(context.Background(), ch); err == nil {
				t.Fatal("no error")
			}
			left := names(spool, ch)
			if !left[""] || !left[".json"] {
				t.Fatalf("deleted before it was verified: left %v", left)
			}
			if err := s.Process(context.Background(), ch); err != nil {
				t.Fatal(err)
			}
			if len(b.ops) != 2 || len(leftovers(spool)) != 0 {
				t.Fatalf("ops %v, left %v", b.ops, leftovers(spool))
			}
		})
	}
}

// A stop (a crash, a power cut) after the last upload's verified and noted,
// before the chunk's deleted: the next try deletes it, uploading nothing
// again.
func TestAStopBeforeTheDeleteUploadsNothingAgain(t *testing.T) {
	for _, cloud := range []bool{false, true} {
		b := &bucket{objects: map[string][]byte{}}
		s, spool := streamer(t, b, "person")
		s.Cloud = cloud
		if err := s.Settings(context.Background(), time.UnixMilli(5)); err != nil {
			t.Fatal(err)
		}
		ch := chunk(t, spool, "video")
		// Stopped where it says it's done, before the delete.
		s.Logf = func(f string, args ...any) {
			if strings.Contains(fmt.Sprintf(f, args...), "deleted here") {
				runtime.Goexit()
			}
		}
		done := make(chan struct{})
		go func() {
			defer close(done)
			s.Process(context.Background(), ch)
		}()
		<-done
		if _, err := os.Stat(ch); err != nil {
			t.Fatal("not stopped before the delete")
		}
		ops := len(b.ops)
		s.Logf = t.Logf
		if err := s.Process(context.Background(), ch); err != nil {
			t.Fatal(err)
		}
		if len(b.ops) != ops {
			t.Errorf("cloud %v: uploaded again: %v", cloud, b.ops[ops:])
		}
		if len(leftovers(spool)) != 0 {
			t.Errorf("cloud %v: left %v", cloud, leftovers(spool))
		}
	}
}
