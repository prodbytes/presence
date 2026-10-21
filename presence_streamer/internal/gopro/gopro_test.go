package gopro

import (
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

	"github.com/prodbytes/presence/presence_streamer/internal/netcam"
	"github.com/prodbytes/presence/presence_streamer/internal/netcam/netcamtest"
)

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

func address(s *httptest.Server) string {
	return strings.TrimPrefix(strings.TrimPrefix(s.URL, "https://"), "http://")
}

func add(name, address, password string) netcam.Request {
	return netcam.Request{Add: &netcam.Add{Name: name, Address: address, Password: password}, RequestedAt: 1}
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
	h := netcamtest.New(t, Kind{}, epoch)

	h.Request(t, add("Helmet", address(srv), "pw"))

	if h.Store.Has(h.RequestKey()) {
		t.Fatal("the request (with the password) is still in the cloud")
	}
	if k := h.Store.Holds(`"pw"`); k != "" {
		t.Fatalf("%s holds the password in the clear", k)
	}
	c, _ := h.Camera("gopro_cam_1")
	if c.Pin == "" || c.Base != srv.URL || c.Password != "pw" {
		t.Fatalf("camera %+v", c)
	}
	if len(h.Registered) != 1 || h.Registered[0][0].DeviceID != "gopro_cam_1" {
		t.Fatalf("registered %+v", h.Registered)
	}
	want := []netcamtest.Clip{
		{Device: "gopro_cam_1", Name: "rec-gopro-20261014T120000.mp4", Content: "video of GL010002.LRV"},
		{Device: "gopro_cam_1", Name: "rec-gopro-20261014T123000.mp4", Content: "video of GOPR0003.MP4"},
	}
	if fmt.Sprint(h.Clips) != fmt.Sprint(want) {
		t.Fatalf("clips %v, want %v", h.Clips, want)
	}
	s := h.Status(t)
	if s.State != netcam.StateOK || s.RequestedAt != 1 || len(s.Cameras) != 1 || s.Cameras[0].Name != "Helmet" ||
		s.Cameras[0].LastFetch == 0 || s.Cameras[0].Error != "" {
		t.Fatalf("status %+v", s)
	}

	// The next fetch: only what's new.
	cam.mu.Lock()
	cam.files = append(cam.files, file{"GX010004.MP4", local(14, 14, 45), false})
	cam.mu.Unlock()
	h.Tick()
	if len(h.Clips) != 3 || h.Clips[2].Content != "video of GX010004.MP4" || len(cam.fetched()) != 3 {
		t.Fatalf("clips %v, fetched %v", h.Clips, cam.fetched())
	}

	// After a restart too (where it got to is saved).
	h.Restart(t)
	h.Tick()
	if len(h.Clips) != 3 {
		t.Fatalf("fetched again: %v", h.Clips)
	}
}

// A wrong password: said, and nothing kept.
func TestAWrongPasswordIsSaidAndNothingKept(t *testing.T) {
	srv := httptest.NewTLSServer(&camera{password: "pw"})
	defer srv.Close()
	h := netcamtest.New(t, Kind{}, epoch)
	h.Request(t, add("Helmet", address(srv), "nope"))
	s := h.Status(t)
	if s.State != netcam.StateError || s.Error != netcam.ErrRefused.Error() || len(h.Cameras()) != 0 || len(h.Registered) != 0 {
		t.Fatalf("status %+v, cameras %v", s, h.Cameras())
	}
	if h.Store.Has(h.RequestKey()) {
		t.Fatal("the request is still in the cloud")
	}
}

// A camera whose certificate isn't the one pinned isn't fetched from.
func TestAChangedCertificateIsRefused(t *testing.T) {
	cam := &camera{password: "pw"}
	srv := httptest.NewTLSServer(cam)
	defer srv.Close()
	h := netcamtest.New(t, Kind{}, epoch)
	h.Request(t, add("Helmet", address(srv), "pw"))
	h.Edit(t, "gopro_cam_1", func(c *netcam.Camera) { c.Pin = strings.Repeat("0", 64) })
	cam.mu.Lock()
	cam.files = []file{{"GX010002.MP4", local(14, 14, 0), false}}
	cam.mu.Unlock()
	h.Tick()
	s := h.Status(t)
	if len(h.Clips) != 0 || !strings.Contains(s.Cameras[0].Error, "certificate changed") {
		t.Fatalf("clips %v, status %+v", h.Clips, s)
	}
}

// Over USB (plain HTTP, no password): the full videos when asked, the ones
// too big skipped; removed, it's forgotten, and the same request isn't
// handled twice.
func TestUSBFullVideosAndRemove(t *testing.T) {
	cam := &camera{files: []file{{"GX010002.MP4", local(14, 14, 0), true}}}
	srv := httptest.NewServer(cam)
	defer srv.Close()
	h := netcamtest.New(t, Kind{Full: true}, epoch)
	h.Request(t, add("Dash", address(srv), ""))
	c, _ := h.Camera("gopro_cam_1")
	if c.Pin != "" || c.Base != srv.URL || len(h.Clips) != 1 || h.Clips[0].Content != "video of GX010002.MP4" {
		t.Fatalf("camera %+v, clips %v", c, h.Clips)
	}

	// Too big: skipped (and not tried again).
	h.M.MaxBytes = 5
	cam.mu.Lock()
	cam.files = append(cam.files, file{"GX010003.MP4", local(14, 14, 30), false})
	cam.mu.Unlock()
	h.Tick()
	if c, _ := h.Camera("gopro_cam_1"); len(h.Clips) != 1 || c.Since != local(14, 14, 30) {
		t.Fatalf("clips %v, camera %+v", h.Clips, c)
	}

	h.Request(t, netcam.Request{Remove: "gopro_cam_1", RequestedAt: 2})
	if len(h.Cameras()) != 0 || len(h.Registered[len(h.Registered)-1]) != 0 || h.Status(t).State != netcam.StateOff {
		t.Fatalf("cameras %v, registered %v", h.Cameras(), h.Registered)
	}
	// The same request again (not deleted, say): not handled twice.
	h.Request(t, add("Dash", address(srv), ""))
	if len(h.Cameras()) != 0 {
		t.Fatalf("handled twice: %v", h.Cameras())
	}
}

// A stop between a video's download and its hand-over: the camera still
// lists it, so the next fetch fetches it again over the leftover and hands
// it over once; one it no longer lists is handed over from the leftover; a
// download cut off is deleted. Nothing stays in gopro-incoming.
func TestALeftoverVideoIsHandedOverOnce(t *testing.T) {
	cam := &camera{}
	srv := httptest.NewServer(cam)
	defer srv.Close()
	h := netcamtest.New(t, Kind{Full: true}, epoch)
	// Added (its first fetch finds nothing yet: the camera's empty).
	h.Request(t, add("Dash", address(srv), ""))
	cam.mu.Lock()
	cam.files = []file{{"GX010002.MP4", local(14, 14, 0), false}}
	cam.mu.Unlock()
	in := filepath.Join(h.M.Dir, "gopro-incoming", "gopro_cam_1")
	os.MkdirAll(in, 0o700)
	os.WriteFile(filepath.Join(in, "rec-gopro-20261014T120000.mp4"), []byte("video of"), 0o600)
	os.WriteFile(filepath.Join(in, "rec-gopro-20261014T115000.mp4"), []byte("gone from the camera"), 0o600)
	os.WriteFile(filepath.Join(in, "rec-gopro-20261014T121000.mp4.part"), []byte("vid"), 0o600)
	h.Tick()
	want := []netcamtest.Clip{
		{Device: "gopro_cam_1", Name: "rec-gopro-20261014T120000.mp4", Content: "video of GX010002.MP4"},
		{Device: "gopro_cam_1", Name: "rec-gopro-20261014T115000.mp4", Content: "gone from the camera"},
	}
	if fmt.Sprint(h.Clips) != fmt.Sprint(want) {
		t.Fatalf("clips %v, want %v", h.Clips, want)
	}
	if left, _ := os.ReadDir(in); len(left) != 0 {
		t.Fatalf("left %v", left)
	}
}

func TestBase(t *testing.T) {
	for _, tc := range []struct {
		address, password, want string
	}{
		{"192.168.1.50", "pw", "https://192.168.1.50"},
		{"172.24.106.51", "", "http://172.24.106.51:8080"},
		{"10.5.5.9:8080", "", "http://10.5.5.9:8080"},
		{" https://gopro.lan:8443/ ", "pw", "https://gopro.lan:8443"},
		{"http://10.5.5.9:8080", "", "http://10.5.5.9:8080"},
		{"", "", ""},
		{"ftp://x", "", ""},
		{"http://x/videos", "", ""},
		{"http://192.168.1.50", "pw", ""},
	} {
		got, err := Kind{}.Base(netcam.Add{Address: tc.address, Password: tc.password})
		if got != tc.want || (err != nil) != (tc.want == "") {
			t.Errorf("Base(%q, %q) = %q, %v; want %q", tc.address, tc.password, got, err, tc.want)
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
