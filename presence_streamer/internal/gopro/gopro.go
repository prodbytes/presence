// Package gopro makes GoPro cameras Presence devices (specs/gopro.md): one
// streamer of the profile, the one the app's Settings pick, reaches each
// camera on the local network with the Open GoPro HTTP API
// (https://gopro.github.io/OpenGoPro/http): over the home network (Camera
// on the Home Network, HTTPS with the camera's password), over USB or the
// camera's own Wi-Fi (plain HTTP on port 8080). Every camera becomes a
// device of its own, with an ID made here, whose new videos go through the
// same chunk pipeline as the Pi's own recordings.
//
// The app and this streamer talk through the profile's folder, sealed with
// this streamer's media key (only the profile's devices hold it):
//
//   - devices/<streamer>/gopro.json, the app's request: {"add": {"name",
//     "address", "password"}} or {"remove": "<device ID>"}, and
//     "requestedAt". Deleted once handled, so the password doesn't stay in
//     the cloud.
//   - devices/<streamer>/gopro-status.json, this streamer's answer:
//     {"state", "error", "cameras": [{"name", "deviceId", "address",
//     "lastFetch", "error"}], "requestedAt", "updatedAt"}.
//
// Here, in the state folder: gopro-state.json (mode 600: the cameras, their
// addresses, passwords and pinned certificates, and where fetching got to).
package gopro

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// States the status says.
const (
	StateOff      = "off"
	StateChecking = "checking"
	StateOK       = "ok"
	StateError    = "error"
)

// Store is the profile's folder in the bucket.
type Store interface {
	Put(ctx context.Context, path, key, contentType string) error
	Get(ctx context.Context, key, path string) error
	Delete(ctx context.Context, key string) error
}

// Add is a camera the app adds.
type Add struct {
	Name     string `json:"name"`
	Address  string `json:"address"`
	Password string `json:"password,omitempty"`
}

// Request is the app's (devices/<streamer>/gopro.json).
type Request struct {
	Add         *Add   `json:"add,omitempty"`
	Remove      string `json:"remove,omitempty"`
	RequestedAt int64  `json:"requestedAt"`
}

// Camera is a GoPro camera and the Presence device it is.
type Camera struct {
	Name     string `json:"name"`
	DeviceID string `json:"deviceId"`
	// Base is the camera's API, e.g. https://192.168.1.50 or
	// http://172.24.106.51:8080.
	Base     string `json:"base"`
	Password string `json:"password,omitempty"`
	// Pin is the SHA-256 of the camera's certificate, pinned when it was
	// added (HTTPS only: the camera signs it with its own CA).
	Pin string `json:"pin,omitempty"`
	// Since is the newest video fetched, in the camera's clock (epoch
	// seconds); only newer ones are fetched.
	Since int64 `json:"since,omitempty"`
}

// Status is this streamer's answer (devices/<streamer>/gopro-status.json).
type Status struct {
	State       string         `json:"state"`
	Error       string         `json:"error,omitempty"`
	Cameras     []StatusCamera `json:"cameras,omitempty"`
	RequestedAt int64          `json:"requestedAt,omitempty"`
	UpdatedAt   int64          `json:"updatedAt"`
}

// StatusCamera is a camera as the app lists it.
type StatusCamera struct {
	Name      string `json:"name"`
	DeviceID  string `json:"deviceId"`
	Address   string `json:"address"`
	LastFetch int64  `json:"lastFetch,omitempty"`
	Error     string `json:"error,omitempty"`
}

// saved is gopro-state.json.
type saved struct {
	Cameras map[string]Camera `json:"cameras,omitempty"`
	// Handled is the requestedAt of the last request handled.
	Handled int64 `json:"handled,omitempty"`
}

// GoPro fetches GoPro cameras' videos for their devices.
type GoPro struct {
	// Dir is the state folder.
	Dir string
	// DeviceID is this streamer's; Key its media key.
	DeviceID string
	Key      []byte
	Store    Store
	// NewDevice makes a camera's device ID.
	NewDevice func() string
	// Cameras is told the cameras whenever they change, so they join the
	// profile's devices and get their pipelines (removed ones stop).
	Cameras func(ctx context.Context, cameras []Camera) error
	// Clip hands a camera's fetched video to its pipeline (it's moved).
	Clip func(ctx context.Context, camera Camera, file string) error
	// Poll is how often the request is looked for; Every how often videos
	// are fetched; Backfill how far back a new camera's first fetch goes.
	Poll, Every, Backfill time.Duration
	// Full fetches the full videos; otherwise the low-resolution copy the
	// camera makes beside each (its .LRV) when there's one.
	Full bool
	// MaxBytes is the biggest video fetched (0: any); bigger ones are
	// skipped.
	MaxBytes int64
	Now      func() time.Time
	Logf     func(string, ...any)

	state     saved
	lastFetch time.Time
	fetched   map[string]int64
	errs      map[string]string
	status    Status
}

func (g *GoPro) statePath() string  { return filepath.Join(g.Dir, "gopro-state.json") }
func (g *GoPro) requestKey() string { return "devices/" + g.DeviceID + "/gopro.json" }
func (g *GoPro) statusKey() string  { return "devices/" + g.DeviceID + "/gopro-status.json" }

func (g *GoPro) now() time.Time {
	if g.Now != nil {
		return g.Now()
	}
	return time.Now()
}

func (g *GoPro) load() {
	g.state = saved{}
	if data, err := os.ReadFile(g.statePath()); err == nil {
		json.Unmarshal(data, &g.state)
	}
	if g.state.Cameras == nil {
		g.state.Cameras = map[string]Camera{}
	}
	if g.fetched == nil {
		g.fetched, g.errs = map[string]int64{}, map[string]string{}
	}
}

func (g *GoPro) save() error { return writeFile(g.statePath(), mustJSON(g.state)) }

func mustJSON(v any) []byte {
	data, _ := json.Marshal(v)
	return data
}

func writeFile(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Known returns the cameras saved, for the start.
func (g *GoPro) Known() []Camera {
	g.load()
	return g.cameraList()
}

func (g *GoPro) cameraList() []Camera {
	out := make([]Camera, 0, len(g.state.Cameras))
	for _, c := range g.state.Cameras {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

// Run looks for the app's requests and fetches videos until ctx ends.
func (g *GoPro) Run(ctx context.Context) error {
	g.load()
	if len(g.state.Cameras) > 0 {
		g.setStatus(ctx, Status{State: StateOK})
	}
	for {
		g.step(ctx)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(g.Poll):
		}
	}
}

// step is one look for a request, and a fetch when it's time.
func (g *GoPro) step(ctx context.Context) {
	req, err := g.request(ctx)
	if err != nil {
		g.Logf("gopro: the request: %v", err)
	}
	if req != nil && req.RequestedAt > g.state.Handled {
		g.handle(ctx, req)
	}
	if len(g.state.Cameras) > 0 && g.now().Sub(g.lastFetch) >= g.Every {
		g.fetch(ctx)
	}
}

// request is the app's request, opened; nil when there's none.
func (g *GoPro) request(ctx context.Context) (*Request, error) {
	tmp, err := os.MkdirTemp(g.Dir, "gopro-req-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	file := filepath.Join(tmp, "gopro.json")
	if err := g.Store.Get(ctx, g.requestKey(), file); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	sealed, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer sealed.Close()
	var plain bytes.Buffer
	if err := seal.Open(&plain, sealed, g.Key); err != nil {
		return nil, fmt.Errorf("the request doesn't open with this device's key: %w", err)
	}
	req := &Request{}
	if err := json.Unmarshal(plain.Bytes(), req); err != nil {
		return nil, err
	}
	return req, nil
}

// handle answers one request: a camera added or removed.
func (g *GoPro) handle(ctx context.Context, req *Request) {
	defer func() {
		g.state.Handled = req.RequestedAt
		if err := g.save(); err != nil {
			g.Logf("gopro: saving: %v", err)
		}
		// The password goes from the cloud once it's been used.
		if err := g.Store.Delete(ctx, g.requestKey()); err != nil {
			g.Logf("gopro: deleting the request: %v", err)
		}
	}()
	switch {
	case req.Remove != "":
		if c, ok := g.state.Cameras[req.Remove]; ok {
			delete(g.state.Cameras, req.Remove)
			g.Logf("gopro: %q removed; its device and events stay", c.Name)
			g.save()
			g.announce(ctx)
		}
		g.setStatus(ctx, Status{State: StateOK, RequestedAt: req.RequestedAt})
	case req.Add != nil:
		g.add(ctx, req)
	}
}

func (g *GoPro) add(ctx context.Context, req *Request) {
	a := req.Add
	name := strings.TrimSpace(a.Name)
	if name == "" {
		name = "GoPro"
	}
	base, err := BaseOf(a.Address, a.Password != "")
	if err != nil {
		g.fail(ctx, req, err.Error())
		return
	}
	g.setStatus(ctx, Status{State: StateChecking, RequestedAt: req.RequestedAt})
	c := Camera{Name: name, Base: base, Password: a.Password}
	// The camera's certificate, pinned now: its CA is the camera's own.
	if strings.HasPrefix(base, "https://") {
		pin, err := fingerprint(ctx, base)
		if err != nil {
			g.fail(ctx, req, "couldn't reach "+a.Address+": "+err.Error())
			return
		}
		c.Pin = pin
	}
	files, err := g.list(ctx, c)
	if err != nil {
		g.fail(ctx, req, "couldn't reach "+a.Address+": "+err.Error())
		return
	}
	// The same camera again (its address): its device stays, the rest is new.
	for id, old := range g.state.Cameras {
		if old.Base == base {
			c.DeviceID, c.Since = id, old.Since
		}
	}
	if c.DeviceID == "" {
		c.DeviceID = g.NewDevice()
		// The first fetch goes back Backfill (in the camera's clock).
		c.Since = g.cameraNow(ctx, c).Add(-g.Backfill).Unix()
		g.Logf("gopro: %q (%s) is device %s, %d file(s) on it", name, base, c.DeviceID, len(files))
	}
	g.state.Cameras[c.DeviceID] = c
	delete(g.errs, c.DeviceID)
	g.save()
	g.announce(ctx)
	g.setStatus(ctx, Status{State: StateOK, RequestedAt: req.RequestedAt})
	g.lastFetch = time.Time{}
}

func (g *GoPro) fail(ctx context.Context, req *Request, why string) {
	g.Logf("gopro: %s", why)
	g.setStatus(ctx, Status{State: StateError, Error: why, RequestedAt: req.RequestedAt})
}

func (g *GoPro) announce(ctx context.Context) {
	if g.Cameras == nil {
		return
	}
	if err := g.Cameras(ctx, g.cameraList()); err != nil {
		g.Logf("gopro: registering the cameras: %v", err)
	}
}

// BaseOf is the camera's API for the address the app gave: an IP address or
// host name (HTTPS with a password, the home network; plain HTTP on port
// 8080 without, USB or the camera's Wi-Fi), or a full http(s) URL.
func BaseOf(address string, password bool) (string, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return "", errors.New("the camera's address is missing")
	}
	if !strings.Contains(address, "://") {
		if password {
			address = "https://" + address
		} else {
			if _, _, err := net.SplitHostPort(address); err != nil {
				address += ":8080"
			}
			address = "http://" + address
		}
	}
	u, err := url.Parse(address)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.Path != "" && u.Path != "/" {
		return "", fmt.Errorf("%q isn't a camera's address (an IP address, or http(s)://host[:port])", address)
	}
	if password && u.Scheme == "http" {
		// Basic auth over plain HTTP would send the password in the clear.
		return "", errors.New("a password needs https:// (the camera on the home network)")
	}
	return u.Scheme + "://" + u.Host, nil
}

// fingerprint is the SHA-256 of the certificate base serves.
func fingerprint(ctx context.Context, base string) (string, error) {
	u, _ := url.Parse(base)
	host := u.Host
	if u.Port() == "" {
		host = net.JoinHostPort(u.Hostname(), "443")
	}
	d := tls.Dialer{Config: &tls.Config{InsecureSkipVerify: true}, NetDialer: &net.Dialer{Timeout: 10 * time.Second}}
	conn, err := d.DialContext(ctx, "tcp", host)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	certs := conn.(*tls.Conn).ConnectionState().PeerCertificates
	if len(certs) == 0 {
		return "", errors.New("no certificate")
	}
	sum := sha256.Sum256(certs[0].Raw)
	return hex.EncodeToString(sum[:]), nil
}

// client talks to c: over HTTPS only to the certificate pinned.
func client(c Camera) *http.Client {
	tr := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
	}
	if c.Pin != "" {
		pin := c.Pin
		tr.TLSClientConfig = &tls.Config{
			// The camera's CA is its own: its certificate is checked against
			// the one pinned when it was added instead.
			InsecureSkipVerify: true,
			VerifyConnection: func(s tls.ConnectionState) error {
				if len(s.PeerCertificates) == 0 {
					return errors.New("no certificate")
				}
				sum := sha256.Sum256(s.PeerCertificates[0].Raw)
				if hex.EncodeToString(sum[:]) != pin {
					return errors.New("the camera's certificate changed: remove it and add it again")
				}
				return nil
			},
		}
	}
	return &http.Client{Transport: tr}
}

func (g *GoPro) get(ctx context.Context, c Camera, p string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.Base+p, nil)
	if err != nil {
		return nil, err
	}
	if c.Password != "" {
		req.SetBasicAuth("gopro", c.Password)
	}
	resp, err := client(c).Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		if resp.StatusCode == http.StatusUnauthorized {
			return nil, errors.New("the camera refused the password")
		}
		return nil, fmt.Errorf("%s: %s", p, resp.Status)
	}
	return resp, nil
}

func (g *GoPro) getJSON(ctx context.Context, c Camera, p string, v any) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	resp, err := g.get(ctx, c, p)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(v)
}

// File is a video on a camera.
type File struct {
	Dir, Name string
	// Created is in the camera's clock, epoch seconds.
	Created int64
	Size    int64
	// LRV: the camera made a low-resolution copy beside it.
	LRV bool
}

// list is the camera's videos, oldest first (GET /gopro/media/list).
func (g *GoPro) list(ctx context.Context, c Camera) ([]File, error) {
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
	if err := g.getJSON(ctx, c, "/gopro/media/list", &media); err != nil {
		return nil, err
	}
	var out []File
	for _, d := range media.Media {
		for _, f := range d.FS {
			if !strings.EqualFold(path.Ext(f.N), ".mp4") || strings.ContainsAny(d.D+f.N, "/\\?#%") {
				continue
			}
			cre, _ := strconv.ParseInt(f.Cre, 10, 64)
			size, _ := strconv.ParseInt(f.S, 10, 64)
			glrv, _ := strconv.ParseInt(f.GLRV, 10, 64)
			out = append(out, File{Dir: d.D, Name: f.N, Created: cre, Size: size, LRV: glrv > 0})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Created < out[j].Created })
	return out, nil
}

// cameraNow is the camera's clock now (GET /gopro/camera/get_date_time:
// its local time, which its files' times are in); the streamer's when the
// camera doesn't say.
func (g *GoPro) cameraNow(ctx context.Context, c Camera) time.Time {
	now := g.now()
	var dt struct {
		Date string `json:"date"`
		Time string `json:"time"`
	}
	if g.getJSON(ctx, c, "/gopro/camera/get_date_time", &dt) != nil {
		return now
	}
	at, err := time.Parse("2006_1_2 15_4_5", dt.Date+" "+dt.Time)
	if err != nil {
		return now
	}
	return at
}

// skew is how far the camera's clock is ahead of UTC, to the quarter hour
// (its time zone, mostly).
func (g *GoPro) skew(ctx context.Context, c Camera) time.Duration {
	return g.cameraNow(ctx, c).Sub(g.now()).Round(15 * time.Minute)
}

// lrvName is the low-resolution copy's name: GX010001.MP4's is
// GL010001.LRV (GH too); GOPR0001.MP4's GOPR0001.LRV.
func lrvName(name string) string {
	base := strings.TrimSuffix(name, path.Ext(name))
	if len(base) > 2 && (strings.HasPrefix(base, "GX") || strings.HasPrefix(base, "GH")) {
		base = "GL" + base[2:]
	}
	return base + ".LRV"
}

// fetch downloads each camera's new videos and hands them over.
func (g *GoPro) fetch(ctx context.Context) {
	g.lastFetch = g.now()
	for _, c := range g.cameraList() {
		if err := g.fetchCamera(ctx, c); err != nil {
			if g.errs[c.DeviceID] != err.Error() {
				g.Logf("gopro: %q: %v", c.Name, err)
			}
			g.errs[c.DeviceID] = err.Error()
		} else {
			delete(g.errs, c.DeviceID)
			g.fetched[c.DeviceID] = g.now().UnixMilli()
		}
	}
	if err := g.save(); err != nil {
		g.Logf("gopro: saving: %v", err)
	}
	g.setStatus(ctx, Status{State: StateOK})
}

func (g *GoPro) fetchCamera(ctx context.Context, c Camera) error {
	files, err := g.list(ctx, c)
	if err != nil {
		return err
	}
	var skew *time.Duration
	for _, f := range files {
		if f.Created <= c.Since {
			continue
		}
		if skew == nil {
			s := g.skew(ctx, c)
			skew = &s
		}
		start := time.Unix(f.Created, 0).Add(-*skew).UTC()
		if err := g.fetchFile(ctx, c, f, start); err != nil {
			return fmt.Errorf("%s: %w", f.Name, err)
		}
		// Where it got to, kept at once: a restart doesn't fetch it again.
		c.Since = f.Created
		if cur, ok := g.state.Cameras[c.DeviceID]; ok {
			cur.Since = c.Since
			g.state.Cameras[c.DeviceID] = cur
			g.save()
		}
	}
	g.leftovers(ctx, c)
	return nil
}

// leftovers hands over the videos a stop left in the camera's incoming
// folder between their download and their hand-over, once a fetch went
// through them all (one the camera still lists is fetched again over it
// before, as where fetching got to hadn't moved on), so none stays here
// unsent. A download cut off (`.part`) is deleted: it's fetched again
// while the camera has it.
func (g *GoPro) leftovers(ctx context.Context, c Camera) {
	dir := filepath.Join(g.Dir, "gopro-incoming", c.DeviceID)
	files, _ := os.ReadDir(dir)
	for _, f := range files {
		file := filepath.Join(dir, f.Name())
		switch {
		case strings.HasSuffix(f.Name(), ".part"):
			os.Remove(file)
		case strings.HasPrefix(f.Name(), "rec-") && strings.HasSuffix(f.Name(), ".mp4"):
			if err := g.Clip(ctx, c, file); err != nil {
				g.Logf("gopro: %q: %s: %v", c.Name, f.Name(), err)
			}
		}
	}
}

func (g *GoPro) fetchFile(ctx context.Context, c Camera, f File, start time.Time) error {
	src := "/videos/DCIM/" + f.Dir + "/" + f.Name
	if !g.Full && f.LRV {
		src = "/videos/DCIM/" + f.Dir + "/" + lrvName(f.Name)
	} else if g.MaxBytes > 0 && f.Size > g.MaxBytes {
		g.Logf("gopro: %q: %s skipped, %d MB is too big", c.Name, f.Name, f.Size>>20)
		return nil
	}
	dir := filepath.Join(g.Dir, "gopro-incoming", c.DeviceID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	out := filepath.Join(dir, "rec-gopro-"+start.Format("20060102T150405")+".mp4")
	resp, err := g.get(ctx, c, src)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	tmp, err := os.OpenFile(out+".part", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	var body io.Reader = resp.Body
	if g.MaxBytes > 0 {
		body = io.LimitReader(resp.Body, g.MaxBytes+1)
	}
	n, err := io.Copy(tmp, body)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil && g.MaxBytes > 0 && n > g.MaxBytes {
		os.Remove(out + ".part")
		g.Logf("gopro: %q: %s skipped, more than %d MB", c.Name, f.Name, g.MaxBytes>>20)
		return nil
	}
	if err != nil {
		os.Remove(out + ".part")
		return err
	}
	if err := os.Rename(out+".part", out); err != nil {
		return err
	}
	g.Logf("gopro: %q: %s fetched (%d MB)", c.Name, path.Base(src), n>>20)
	return g.Clip(ctx, c, out)
}

// setStatus publishes the status, sealed, with the cameras.
func (g *GoPro) setStatus(ctx context.Context, s Status) {
	if s.RequestedAt == 0 {
		s.RequestedAt = g.state.Handled
	}
	for _, c := range g.cameraList() {
		s.Cameras = append(s.Cameras, StatusCamera{
			Name: c.Name, DeviceID: c.DeviceID, Address: c.Base,
			LastFetch: g.fetched[c.DeviceID], Error: g.errs[c.DeviceID],
		})
	}
	if s.State == StateOK && len(s.Cameras) == 0 {
		s.State = StateOff
	}
	s.UpdatedAt = g.now().UnixMilli()
	g.status = s
	plain := filepath.Join(g.Dir, "gopro-status.json")
	if err := writeFile(plain, mustJSON(s)); err != nil {
		g.Logf("gopro: status: %v", err)
		return
	}
	defer os.Remove(plain)
	sealed := plain + ".sealed"
	if err := seal.File(plain, sealed, g.Key, g.DeviceID); err != nil {
		g.Logf("gopro: status: %v", err)
		return
	}
	defer os.Remove(sealed)
	if err := g.Store.Put(ctx, sealed, g.statusKey(), "application/octet-stream"); err != nil {
		g.Logf("gopro: status: %v", err)
	}
}
