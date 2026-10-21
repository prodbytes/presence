package reolink

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/netcam"
	"github.com/prodbytes/presence/presence_streamer/internal/netcam/netcamtest"
)

// The streamer's clock: 2026-10-14 13:00 UTC. The camera's is two hours
// ahead (its time zone), and its recordings' times are in it.
var epoch = time.Date(2026, 10, 14, 13, 0, 0, 0, time.UTC)

func local(day, hour, minute int) time.Time {
	return time.Date(2026, 10, day, hour, minute, 0, 0, time.UTC)
}

type recording struct {
	channel int
	stream  string
	start   time.Time
}

func (r recording) name() string {
	return fmt.Sprintf("Mp4Record/%s/Rec%s_%s.mp4", r.start.Format("2006-01-02"), strings.ToUpper(r.stream[:1]), r.start.Format("20060102_150405"))
}

// camera is Reolink's HTTP API, faked: admin / pw, tokens, its clock, its
// recordings (searched a day at a time), downloads and logouts.
type camera struct {
	mu         sync.Mutex
	recordings []recording
	tokens     map[string]bool
	searches   []string
	downloads  []string
	logins     int
}

func (c *camera) answer(w http.ResponseWriter, cmd string, value any, code int, detail string) {
	a := map[string]any{"cmd": cmd, "code": code}
	if code == 0 {
		a["value"] = value
	} else {
		a["error"] = map[string]any{"detail": detail, "rspCode": -7}
	}
	json.NewEncoder(w).Encode([]any{a})
}

func (c *camera) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if r.URL.Path != "/cgi-bin/api.cgi" {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	cmd := r.URL.Query().Get("cmd")
	var body []struct {
		Param json.RawMessage `json:"param"`
	}
	if r.Method == http.MethodPost {
		json.NewDecoder(r.Body).Decode(&body)
	}
	if cmd == "Login" {
		var p struct {
			User struct{ UserName, Password string }
		}
		json.Unmarshal(body[0].Param, &p)
		if p.User.UserName != "admin" || p.User.Password != "pw" {
			c.answer(w, cmd, nil, 1, "login failed")
			return
		}
		c.logins++
		token := fmt.Sprintf("t%d", c.logins)
		c.tokens[token] = true
		c.answer(w, cmd, map[string]any{"Token": map[string]any{"leaseTime": 3600, "name": token}}, 0, "")
		return
	}
	if !c.tokens[r.URL.Query().Get("token")] {
		c.answer(w, cmd, nil, 1, "please login first")
		return
	}
	switch cmd {
	case "Logout":
		delete(c.tokens, r.URL.Query().Get("token"))
		c.answer(w, cmd, map[string]any{"rspCode": 200}, 0, "")
	case "GetTime":
		c.answer(w, cmd, map[string]any{"Time": stampOf(epoch.Add(2 * time.Hour))}, 0, "")
	case "Search":
		var p struct {
			Search struct {
				Channel            int    `json:"channel"`
				StreamType         string `json:"streamType"`
				StartTime, EndTime stamp
			}
		}
		json.Unmarshal(body[0].Param, &p)
		q := p.Search
		if q.StartTime.Day != q.EndTime.Day {
			c.answer(w, cmd, nil, 1, "one day at a time")
			return
		}
		c.searches = append(c.searches, fmt.Sprintf("%s %02d", q.StreamType, q.StartTime.Day))
		var files []any
		for _, rec := range c.recordings {
			if rec.channel == q.Channel && rec.stream == q.StreamType &&
				!rec.start.Before(q.StartTime.time()) && !rec.start.After(q.EndTime.time()) {
				files = append(files, map[string]any{"name": rec.name(), "size": "6", "type": rec.stream, "StartTime": stampOf(rec.start)})
			}
		}
		c.answer(w, cmd, map[string]any{"SearchResult": map[string]any{"channel": q.Channel, "File": files}}, 0, "")
	case "Download":
		source := r.URL.Query().Get("source")
		c.downloads = append(c.downloads, source)
		w.Header().Set("Content-Type", "video/mp4")
		w.Write([]byte("video of " + source))
	default:
		c.answer(w, cmd, nil, 1, "not supported")
	}
}

func (c *camera) add(r ...recording) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.recordings = append(c.recordings, r...)
}

func (c *camera) open() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.tokens)
}

func newCamera(r ...recording) (*camera, *httptest.Server) {
	c := &camera{recordings: r, tokens: map[string]bool{}}
	return c, httptest.NewTLSServer(c)
}

func address(s *httptest.Server) string { return strings.TrimPrefix(s.URL, "https://") }

func add(address, password string, channel int) netcam.Request {
	return netcam.Request{Add: &netcam.Add{Name: "Porch", Address: address, Username: "admin", Password: password, Channel: channel}, RequestedAt: 1}
}

// Added: logged in over HTTPS (its certificate pinned), the request deleted
// (the password nowhere in the cloud), a device of its own; its sub
// stream's recordings since the backfill fetched (main's on a day with no
// sub stream), each a day's search, named by their UTC start, each once;
// every session logged out.
func TestAddFetchesTheRecordingsOnce(t *testing.T) {
	cam, srv := newCamera(
		recording{0, "sub", local(13, 10, 0)}, // before the backfill
		recording{0, "sub", local(13, 20, 0)},
		recording{0, "main", local(13, 20, 0)},
		recording{0, "sub", local(14, 14, 0)},
		recording{0, "main", local(14, 14, 0)},
		recording{1, "sub", local(14, 14, 10)}, // another channel
	)
	defer srv.Close()
	h := netcamtest.New(t, Kind{}, epoch)

	h.Request(t, add(address(srv), "pw", 0))

	if h.Store.Has(h.RequestKey()) {
		t.Fatal("the request (with the password) is still in the cloud")
	}
	if k := h.Store.Holds(`"pw"`); k != "" {
		t.Fatalf("%s holds the password in the clear", k)
	}
	c, _ := h.Camera("reolink_cam_1")
	if c.Pin == "" || c.Base != srv.URL || c.Username != "admin" {
		t.Fatalf("camera %+v", c)
	}
	want := []netcamtest.Clip{
		{Device: "reolink_cam_1", Name: "rec-reolink-20261013T180000.mp4", Content: "video of Mp4Record/2026-10-13/RecS_20261013_200000.mp4"},
		{Device: "reolink_cam_1", Name: "rec-reolink-20261014T120000.mp4", Content: "video of Mp4Record/2026-10-14/RecS_20261014_140000.mp4"},
	}
	if fmt.Sprint(h.Clips) != fmt.Sprint(want) {
		t.Fatalf("clips %v, want %v", h.Clips, want)
	}
	if cam.open() != 0 {
		t.Fatalf("%d session(s) left open", cam.open())
	}

	// The next fetch: only what's new; a day with only the main stream's.
	cam.add(recording{0, "main", local(14, 14, 30)})
	h.Tick()
	if len(h.Clips) != 3 || h.Clips[2].Content != "video of Mp4Record/2026-10-14/RecM_20261014_143000.mp4" {
		t.Fatalf("clips %v", h.Clips)
	}
	h.Restart(t)
	h.Tick()
	if len(h.Clips) != 3 || cam.open() != 0 {
		t.Fatalf("clips %v, open %d", h.Clips, cam.open())
	}
	s := h.Status(t)
	if s.State != netcam.StateOK || len(s.Cameras) != 1 || s.Cameras[0].LastFetch == 0 || s.Cameras[0].Error != "" {
		t.Fatalf("status %+v", s)
	}
}

// An NVR's channel: its own camera; Full: the main stream's.
func TestAnNVRChannelAndFull(t *testing.T) {
	_, srv := newCamera(
		recording{0, "sub", local(14, 14, 0)},
		recording{1, "sub", local(14, 14, 10)},
		recording{1, "main", local(14, 14, 10)},
	)
	defer srv.Close()
	h := netcamtest.New(t, Kind{Full: true}, epoch)
	h.Request(t, add(address(srv), "pw", 1))
	if len(h.Clips) != 1 || h.Clips[0].Content != "video of Mp4Record/2026-10-14/RecM_20261014_141000.mp4" {
		t.Fatalf("clips %v", h.Clips)
	}
	if c, _ := h.Camera("reolink_cam_1"); c.Channel != 1 || h.Status(t).Cameras[0].Channel != 1 {
		t.Fatalf("camera %+v", c)
	}
}

// A wrong password: said, and nothing kept.
func TestAWrongPasswordIsSaidAndNothingKept(t *testing.T) {
	_, srv := newCamera()
	defer srv.Close()
	h := netcamtest.New(t, Kind{}, epoch)
	h.Request(t, add(address(srv), "nope", 0))
	s := h.Status(t)
	if s.State != netcam.StateError || !strings.Contains(s.Error, netcam.ErrRefused.Error()) || len(h.Cameras()) != 0 {
		t.Fatalf("status %+v, cameras %v", s, h.Cameras())
	}
	if h.Store.Has(h.RequestKey()) {
		t.Fatal("the request is still in the cloud")
	}
}

func TestBase(t *testing.T) {
	for _, tc := range []struct{ address, password, want string }{
		{"192.168.1.60", "pw", "https://192.168.1.60"},
		{"https://nvr.lan:8443", "pw", "https://nvr.lan:8443"},
		{"http://192.168.1.60", "pw", ""},
		{"192.168.1.60", "", ""},
	} {
		got, err := Kind{}.Base(netcam.Add{Address: tc.address, Password: tc.password})
		if got != tc.want || (err != nil) != (tc.want == "") {
			t.Errorf("Base(%q, %q) = %q, %v; want %q", tc.address, tc.password, got, err, tc.want)
		}
	}
}
