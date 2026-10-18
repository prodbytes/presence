package gopro

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// memStore is the profile's folder, in memory.
type memStore struct {
	mu      sync.Mutex
	objects map[string][]byte
}

func (m *memStore) Put(_ context.Context, path, key, _ string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.objects[key] = data
	return nil
}

func (m *memStore) Get(_ context.Context, key, path string) error {
	m.mu.Lock()
	data, ok := m.objects[key]
	m.mu.Unlock()
	if !ok {
		return fmt.Errorf("%s: %w", key, os.ErrNotExist)
	}
	return os.WriteFile(path, data, 0o600)
}

func (m *memStore) Delete(_ context.Context, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.objects, key)
	return nil
}

var key = bytes.Repeat([]byte{7}, 32)

// put writes the app's request, sealed with the streamer's key.
func (m *memStore) put(t *testing.T, req Request) {
	var sealed bytes.Buffer
	data, _ := json.Marshal(req)
	if err := seal.Seal(&sealed, bytes.NewReader(data), key, "calm_quiet_otter", nil); err != nil {
		t.Fatal(err)
	}
	m.mu.Lock()
	m.objects["devices/calm_quiet_otter/gopro.json"] = sealed.Bytes()
	m.mu.Unlock()
}

func (m *memStore) has(k string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.objects[k]
	return ok
}

// status opens the streamer's status.
func (m *memStore) status(t *testing.T) Status {
	m.mu.Lock()
	sealed := m.objects["devices/calm_quiet_otter/gopro-status.json"]
	m.mu.Unlock()
	var plain bytes.Buffer
	if err := seal.Open(&plain, bytes.NewReader(sealed), key); err != nil {
		t.Fatal(err)
	}
	var s Status
	json.Unmarshal(plain.Bytes(), &s)
	return s
}

// The streamer's clock: 2026-10-14 13:00 UTC. The camera's is two hours
// ahead (its time zone), and its files' times are in it.
var epoch = time.Date(2026, 10, 14, 13, 0, 0, 0, time.UTC)

func local(day, hour, minute int) int64 {
	return time.Date(2026, 10, day, hour, minute, 0, 0, time.UTC).Unix()
}

type file struct {
	name string
	cre  int64
	lrv  bool
}

// camera is the Open GoPro HTTP API, faked: the password "pw" (when it
// wants one), its media list, its clock, and its files.
type camera struct {
	mu       sync.Mutex
	password string
	files    []file
	gets     []string
}

func (c *camera) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.password != "" {
		if u, p, ok := r.BasicAuth(); !ok || u != "gopro" || p != c.password {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
	}
	switch {
	case r.URL.Path == "/gopro/media/list":
		var fs []map[string]string
		for _, f := range c.files {
			m := map[string]string{"n": f.name, "cre": fmt.Sprint(f.cre), "s": "6"}
			if f.lrv {
				m["glrv"] = "3"
			}
			fs = append(fs, m)
		}
		fs = append(fs, map[string]string{"n": "GOPR0009.JPG", "cre": fmt.Sprint(local(14, 14, 50)), "s": "1"})
		json.NewEncoder(w).Encode(map[string]any{"id": "1", "media": []any{map[string]any{"d": "100GOPRO", "fs": fs}}})
	case r.URL.Path == "/gopro/camera/get_date_time":
		at := epoch.Add(2 * time.Hour)
		json.NewEncoder(w).Encode(map[string]any{"date": at.Format("2006_1_2"), "time": at.Format("15_4_5"), "tzone": 120})
	case strings.HasPrefix(r.URL.Path, "/videos/DCIM/100GOPRO/"):
		c.gets = append(c.gets, r.URL.Path)
		w.Write([]byte("video of " + strings.TrimPrefix(r.URL.Path, "/videos/DCIM/100GOPRO/")))
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (c *camera) fetched() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.gets...)
}

type clip struct{ device, name, content string }

func newGoPro(t *testing.T) (*GoPro, *memStore, *[]clip, *[][]Camera) {
	dir := t.TempDir()
	store := &memStore{objects: map[string][]byte{}}
	var clips []clip
	var registered [][]Camera
	n := 0
	g := &GoPro{
		Dir: dir, DeviceID: "calm_quiet_otter", Key: key, Store: store,
		NewDevice: func() string { n++; return fmt.Sprintf("gopro_cam_%d", n) },
		Cameras: func(_ context.Context, cameras []Camera) error {
			registered = append(registered, cameras)
			return nil
		},
		Clip: func(_ context.Context, c Camera, f string) error {
			data, _ := os.ReadFile(f)
			clips = append(clips, clip{c.DeviceID, filepath.Base(f), string(data)})
			return os.Remove(f)
		},
		Poll: time.Millisecond, Every: 2 * time.Minute, Backfill: 24 * time.Hour,
		Now:  func() time.Time { return epoch },
		Logf: t.Logf,
	}
	g.load()
	return g, store, &clips, &registered
}

func address(s *httptest.Server) string {
	return strings.TrimPrefix(strings.TrimPrefix(s.URL, "https://"), "http://")
}

// Added over the home network (HTTPS, a password): its certificate pinned,
// the request deleted (the password nowhere in the cloud), a device of its
// own; then its videos since the backfill fetched (the low-resolution copy
// when there's one), named by their UTC start, each once.
func TestAddFetchesNewVideosOnce(t *testing.T) {
	cam := &camera{password: "pw", files: []file{
		{"GX010001.MP4", local(13, 10, 0), true}, // before the backfill
		{"GX010002.MP4", local(14, 14, 0), true},
		{"GOPR0003.MP4", local(14, 14, 30), false},
	}}
	srv := httptest.NewTLSServer(cam)
	defer srv.Close()
	g, store, clips, registered := newGoPro(t)
	ctx := context.Background()

	store.put(t, Request{Add: &Add{Name: "Helmet", Address: address(srv), Password: "pw"}, RequestedAt: 1})
	g.step(ctx)

	if store.has("devices/calm_quiet_otter/gopro.json") {
		t.Fatal("the request (with the password) is still in the cloud")
	}
	for k, v := range store.objects {
		if bytes.Contains(v, []byte("pw\"")) {
			t.Fatalf("%s holds the password in the clear", k)
		}
	}
	c := g.state.Cameras["gopro_cam_1"]
	if c.Pin == "" || c.Base != srv.URL || c.Password != "pw" {
		t.Fatalf("camera %+v", c)
	}
	if len(*registered) != 1 || (*registered)[0][0].DeviceID != "gopro_cam_1" {
		t.Fatalf("registered %+v", *registered)
	}
	want := []clip{
		{"gopro_cam_1", "rec-gopro-20261014T120000.mp4", "video of GL010002.LRV"},
		{"gopro_cam_1", "rec-gopro-20261014T123000.mp4", "video of GOPR0003.MP4"},
	}
	if fmt.Sprint(*clips) != fmt.Sprint(want) {
		t.Fatalf("clips %v, want %v", *clips, want)
	}
	s := store.status(t)
	if s.State != StateOK || s.RequestedAt != 1 || len(s.Cameras) != 1 || s.Cameras[0].Name != "Helmet" ||
		s.Cameras[0].LastFetch == 0 || s.Cameras[0].Error != "" {
		t.Fatalf("status %+v", s)
	}

	// The next fetch: only what's new.
	cam.mu.Lock()
	cam.files = append(cam.files, file{"GX010004.MP4", local(14, 14, 45), false})
	cam.mu.Unlock()
	g.lastFetch = time.Time{}
	g.step(ctx)
	if len(*clips) != 3 || (*clips)[2].content != "video of GX010004.MP4" || len(cam.fetched()) != 3 {
		t.Fatalf("clips %v, fetched %v", *clips, cam.fetched())
	}

	// After a restart too (where it got to is saved).
	g2, _, clips2, _ := newGoPro(t)
	g2.Dir, g2.Store = g.Dir, store
	g2.load()
	g2.step(ctx)
	if len(*clips2) != 0 {
		t.Fatalf("fetched again: %v", *clips2)
	}
}

// A wrong password: said, and nothing kept.
func TestAWrongPasswordIsSaidAndNothingKept(t *testing.T) {
	srv := httptest.NewTLSServer(&camera{password: "pw"})
	defer srv.Close()
	g, store, _, registered := newGoPro(t)
	store.put(t, Request{Add: &Add{Name: "Helmet", Address: address(srv), Password: "nope"}, RequestedAt: 1})
	g.step(context.Background())
	s := store.status(t)
	if s.State != StateError || !strings.Contains(s.Error, "refused the password") || len(g.state.Cameras) != 0 || len(*registered) != 0 {
		t.Fatalf("status %+v, cameras %v", s, g.state.Cameras)
	}
	if store.has("devices/calm_quiet_otter/gopro.json") {
		t.Fatal("the request is still in the cloud")
	}
}

// A camera whose certificate isn't the one pinned isn't fetched from.
func TestAChangedCertificateIsRefused(t *testing.T) {
	cam := &camera{password: "pw", files: []file{{"GX010002.MP4", local(14, 14, 0), false}}}
	srv := httptest.NewTLSServer(cam)
	defer srv.Close()
	g, store, clips, _ := newGoPro(t)
	store.put(t, Request{Add: &Add{Name: "Helmet", Address: address(srv), Password: "pw"}, RequestedAt: 1})
	g.handle(context.Background(), &Request{Add: &Add{Name: "Helmet", Address: address(srv), Password: "pw"}, RequestedAt: 1})
	c := g.state.Cameras["gopro_cam_1"]
	c.Pin = strings.Repeat("0", 64)
	g.state.Cameras["gopro_cam_1"] = c
	g.fetch(context.Background())
	s := store.status(t)
	if len(*clips) != 0 || !strings.Contains(s.Cameras[0].Error, "certificate changed") {
		t.Fatalf("clips %v, status %+v", *clips, s)
	}
}

// Over USB (plain HTTP, no password): the full videos when asked, the ones
// too big skipped; removed, it's forgotten (and its pipeline stops), and
// the same request isn't handled twice.
func TestUSBFullVideosAndRemove(t *testing.T) {
	cam := &camera{files: []file{
		{"GX010002.MP4", local(14, 14, 0), true},
	}}
	srv := httptest.NewServer(cam)
	defer srv.Close()
	g, store, clips, registered := newGoPro(t)
	g.Full = true
	ctx := context.Background()
	store.put(t, Request{Add: &Add{Name: "Dash", Address: address(srv)}, RequestedAt: 1})
	g.step(ctx)
	c := g.state.Cameras["gopro_cam_1"]
	if c.Pin != "" || c.Base != srv.URL || len(*clips) != 1 || (*clips)[0].content != "video of GX010002.MP4" {
		t.Fatalf("camera %+v, clips %v", c, *clips)
	}

	// Too big: skipped (and not tried again).
	g.MaxBytes = 5
	cam.mu.Lock()
	cam.files = append(cam.files, file{"GX010003.MP4", local(14, 14, 30), false})
	cam.mu.Unlock()
	g.lastFetch = time.Time{}
	g.step(ctx)
	if len(*clips) != 1 || g.state.Cameras["gopro_cam_1"].Since != local(14, 14, 30) {
		t.Fatalf("clips %v, camera %+v", *clips, g.state.Cameras["gopro_cam_1"])
	}

	store.put(t, Request{Remove: "gopro_cam_1", RequestedAt: 2})
	g.step(ctx)
	if len(g.state.Cameras) != 0 || len((*registered)[len(*registered)-1]) != 0 || store.status(t).State != StateOff {
		t.Fatalf("cameras %v, registered %v", g.state.Cameras, *registered)
	}
	// The same request again (not deleted, say): not handled twice.
	store.put(t, Request{Add: &Add{Name: "Dash", Address: address(srv)}, RequestedAt: 1})
	g.step(ctx)
	if len(g.state.Cameras) != 0 {
		t.Fatalf("handled twice: %v", g.state.Cameras)
	}
}

func TestBaseOf(t *testing.T) {
	for _, tc := range []struct {
		address  string
		password bool
		want     string
	}{
		{"192.168.1.50", true, "https://192.168.1.50"},
		{"172.24.106.51", false, "http://172.24.106.51:8080"},
		{"10.5.5.9:8080", false, "http://10.5.5.9:8080"},
		{" https://gopro.lan:8443/ ", true, "https://gopro.lan:8443"},
		{"http://10.5.5.9:8080", false, "http://10.5.5.9:8080"},
		{"", false, ""},
		{"ftp://x", false, ""},
		{"http://x/videos", false, ""},
		{"http://192.168.1.50", true, ""},
	} {
		got, err := BaseOf(tc.address, tc.password)
		if got != tc.want || (err != nil) != (tc.want == "") {
			t.Errorf("BaseOf(%q, %v) = %q, %v; want %q", tc.address, tc.password, got, err, tc.want)
		}
	}
}

func TestLRVName(t *testing.T) {
	for in, want := range map[string]string{"GX010002.MP4": "GL010002.LRV", "GH010002.MP4": "GL010002.LRV", "GOPR0003.MP4": "GOPR0003.LRV"} {
		if got := lrvName(in); got != want {
			t.Errorf("lrvName(%q) = %q, want %q", in, got, want)
		}
	}
}
