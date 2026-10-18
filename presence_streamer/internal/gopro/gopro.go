// Package gopro is GoPro's kind of network camera (specs/gopro.md, the
// netcam package): the streamer reaches each camera with the Open GoPro
// HTTP API (https://gopro.github.io/OpenGoPro/http): over the home network
// (Camera on the Home Network, HTTPS with the camera's password), over USB
// or the camera's own Wi-Fi (plain HTTP on port 8080).
package gopro

import (
	"context"
	"io"
	"net/http"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/netcam"
)

// Kind is GoPro's.
type Kind struct {
	// Full fetches the full videos; otherwise the low-resolution copy the
	// camera makes beside each (its .LRV) when there's one.
	Full bool
}

// Name names its files ("gopro.json").
func (Kind) Name() string { return "gopro" }

// Base is the camera's API: HTTPS with a password (the home network); plain
// HTTP on port 8080 without (USB, the camera's Wi-Fi).
func (Kind) Base(a netcam.Add) (string, error) {
	return netcam.BaseOf(a.Address, a.Password == "", "8080", a.Password != "")
}

// Login reaches the camera: its media list.
func (k Kind) Login(ctx context.Context, c *netcam.Conn) (netcam.Session, error) {
	s := &session{kind: k, c: c, lrv: map[string]bool{}}
	return s, s.list(ctx)
}

type session struct {
	kind  Kind
	c     *netcam.Conn
	files []netcam.Video
	lrv   map[string]bool
}

func (s *session) get(ctx context.Context, p string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.c.Camera.Base+p, nil)
	if err != nil {
		return nil, err
	}
	if s.c.Camera.Password != "" {
		req.SetBasicAuth("gopro", s.c.Camera.Password)
	}
	return s.c.Do(req)
}

func (s *session) getJSON(ctx context.Context, p string, v any) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := s.get(ctx, p)
	if err != nil {
		return err
	}
	return netcam.JSON(resp, v)
}

// list reads the camera's videos (GET /gopro/media/list), oldest first.
func (s *session) list(ctx context.Context) error {
	var media struct {
		Media []struct {
			D  string `json:"d"`
			FS []struct {
				N    string `json:"n"`
				Cre  string `json:"cre"`
				S    string `json:"s"`
				GLRV string `json:"glrv"`
			} `json:"fs"`
		} `json:"media"`
	}
	if err := s.getJSON(ctx, "/gopro/media/list", &media); err != nil {
		return err
	}
	for _, d := range media.Media {
		for _, f := range d.FS {
			if !strings.EqualFold(path.Ext(f.N), ".mp4") || strings.ContainsAny(d.D+f.N, "/\\?#%") {
				continue
			}
			cre, _ := strconv.ParseInt(f.Cre, 10, 64)
			size, _ := strconv.ParseInt(f.S, 10, 64)
			glrv, _ := strconv.ParseInt(f.GLRV, 10, 64)
			id := d.D + "/" + f.N
			if glrv > 0 && !s.kind.Full {
				// The low-resolution copy is fetched instead: its size isn't
				// the full video's.
				s.lrv[id], size = true, 0
			}
			s.files = append(s.files, netcam.Video{ID: id, Created: cre, Size: size})
		}
	}
	sort.Slice(s.files, func(i, j int) bool { return s.files[i].Created < s.files[j].Created })
	return nil
}

// Now is the camera's clock (GET /gopro/camera/get_date_time: its local
// time, which its files' times are in).
func (s *session) Now(ctx context.Context) (time.Time, bool) {
	var dt struct {
		Date string `json:"date"`
		Time string `json:"time"`
	}
	if s.getJSON(ctx, "/gopro/camera/get_date_time", &dt) != nil {
		return time.Time{}, false
	}
	at, err := time.Parse("2006_1_2 15_4_5", dt.Date+" "+dt.Time)
	return at, err == nil
}

func (s *session) Videos(_ context.Context, since int64) ([]netcam.Video, error) {
	var out []netcam.Video
	for _, f := range s.files {
		if f.Created > since {
			out = append(out, f)
		}
	}
	return out, nil
}

func (s *session) Open(ctx context.Context, v netcam.Video) (io.ReadCloser, error) {
	src := v.ID
	if s.lrv[v.ID] {
		src = path.Dir(v.ID) + "/" + lrvName(path.Base(v.ID))
	}
	resp, err := s.get(ctx, "/videos/DCIM/"+src)
	if err != nil {
		return nil, err
	}
	return resp.Body, nil
}

func (s *session) Close() {}

// lrvName is the low-resolution copy's name: GX010001.MP4's is
// GL010001.LRV (GH too); GOPR0001.MP4's GOPR0001.LRV.
func lrvName(name string) string {
	base := strings.TrimSuffix(name, path.Ext(name))
	if len(base) > 2 && (strings.HasPrefix(base, "GX") || strings.HasPrefix(base, "GH")) {
		base = "GL" + base[2:]
	}
	return base + ".LRV"
}
