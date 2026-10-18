// Package netcam makes cameras on the streamer's network Presence devices
// (specs/gopro.md, specs/reolink.md): one streamer of the profile, the one
// the app's Settings pick, reaches each camera with its own HTTP API (a
// Kind: GoPro's, Reolink's) and fetches the videos it recorded. Every camera
// becomes a device of its own, with an ID made here, whose videos go
// through the same chunk pipeline as the Pi's own recordings.
//
// The app and this streamer talk through the profile's folder, sealed with
// this streamer's media key (only the profile's devices hold it), in files
// named after the kind (<kind> is "gopro", "reolink"):
//
//   - devices/<streamer>/<kind>.json, the app's request: {"add": {"name",
//     "address", "username", "password", "channel"}} or {"remove": "<device
//     ID>"}, and "requestedAt". Deleted once handled, so the password
//     doesn't stay in the cloud.
//   - devices/<streamer>/<kind>-status.json, this streamer's answer:
//     {"state", "error", "cameras": [{"name", "deviceId", "address",
//     "channel", "lastFetch", "error"}], "requestedAt", "updatedAt"}.
//
// Here, in the state folder: <kind>-state.json (mode 600: the cameras,
// their addresses, logins and pinned certificates, and where fetching got
// to).
package netcam

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
	"path/filepath"
	"sort"
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

// ErrRefused is a camera refusing the login.
var ErrRefused = errors.New("the camera refused the user or password")

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
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
	// Channel is an NVR's camera (0: the first, or a camera on its own).
	Channel int `json:"channel,omitempty"`
}

// Request is the app's (devices/<streamer>/<kind>.json).
type Request struct {
	Add         *Add   `json:"add,omitempty"`
	Remove      string `json:"remove,omitempty"`
	RequestedAt int64  `json:"requestedAt"`
}

// Camera is a camera and the Presence device it is.
type Camera struct {
	Name     string `json:"name"`
	DeviceID string `json:"deviceId"`
	// Base is the camera's API, e.g. https://192.168.1.50 or
	// http://172.24.106.51:8080.
	Base     string `json:"base"`
	Username string `json:"username,omitempty"`
	Password string `json:"password,omitempty"`
	Channel  int    `json:"channel,omitempty"`
	// Pin is the SHA-256 of the camera's certificate, pinned when it was
	// added (HTTPS only: cameras sign their own).
	Pin string `json:"pin,omitempty"`
	// Since is the newest video fetched, in the camera's clock (epoch
	// seconds, its local time read as UTC); only newer ones are fetched.
	Since int64 `json:"since,omitempty"`
}

// Video is a video on a camera.
type Video struct {
	// ID is what the kind fetches it by (a file's path on the camera).
	ID string
	// Created is when it started, in the camera's clock (epoch seconds,
	// its local time read as UTC).
	Created int64
	// Size is in bytes, 0 when not known.
	Size int64
}

// Kind is a make of camera: how its API is reached.
type Kind interface {
	// Name names its files, spool and logs ("gopro").
	Name() string
	// Base is the camera's API for what the app gave, or why it can't be.
	Base(a Add) (string, error)
	// Login reaches the camera (and logs in, when it has a login);
	// ErrRefused when it refuses the login.
	Login(ctx context.Context, c *Conn) (Session, error)
}

// Session is a camera reached.
type Session interface {
	// Now is the camera's clock now (its local time, read as UTC); false
	// when it doesn't say.
	Now(ctx context.Context) (time.Time, bool)
	// Videos are its videos newer than since (the camera's clock), oldest
	// first.
	Videos(ctx context.Context, since int64) ([]Video, error)
	// Open downloads a video.
	Open(ctx context.Context, v Video) (io.ReadCloser, error)
	// Close logs out.
	Close()
}

// Status is this streamer's answer (devices/<streamer>/<kind>-status.json).
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
	Channel   int    `json:"channel,omitempty"`
	LastFetch int64  `json:"lastFetch,omitempty"`
	Error     string `json:"error,omitempty"`
}

// saved is <kind>-state.json.
type saved struct {
	Cameras map[string]Camera `json:"cameras,omitempty"`
	// Handled is the requestedAt of the last request handled.
	Handled int64 `json:"handled,omitempty"`
}

// Manager fetches a kind's cameras' videos for their devices.
type Manager struct {
	Kind Kind
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
	// MaxBytes is the biggest video fetched (0: any); bigger ones are
	// skipped.
	MaxBytes int64
	Now      func() time.Time
	Logf     func(string, ...any)

	state     saved
	lastFetch time.Time
	fetched   map[string]int64
	errs      map[string]string
}

func (m *Manager) name() string       { return m.Kind.Name() }
func (m *Manager) statePath() string  { return filepath.Join(m.Dir, m.name()+"-state.json") }
func (m *Manager) requestKey() string { return "devices/" + m.DeviceID + "/" + m.name() + ".json" }
func (m *Manager) statusKey() string {
	return "devices/" + m.DeviceID + "/" + m.name() + "-status.json"
}

func (m *Manager) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func (m *Manager) logf(format string, args ...any) {
	m.Logf(m.name()+": "+format, args...)
}

func (m *Manager) load() {
	m.state = saved{}
	if data, err := os.ReadFile(m.statePath()); err == nil {
		json.Unmarshal(data, &m.state)
	}
	if m.state.Cameras == nil {
		m.state.Cameras = map[string]Camera{}
	}
	if m.fetched == nil {
		m.fetched, m.errs = map[string]int64{}, map[string]string{}
	}
}

func (m *Manager) save() error { return writeFile(m.statePath(), mustJSON(m.state)) }

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

// Known returns the cameras saved (it loads them: for the start).
func (m *Manager) Known() []Camera {
	m.load()
	return m.cameraList()
}

func (m *Manager) cameraList() []Camera {
	out := make([]Camera, 0, len(m.state.Cameras))
	for _, c := range m.state.Cameras {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

// Run looks for the app's requests and fetches videos until ctx ends.
func (m *Manager) Run(ctx context.Context) error {
	m.load()
	if len(m.state.Cameras) > 0 {
		m.setStatus(ctx, Status{State: StateOK})
	}
	for {
		m.Step(ctx)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(m.Poll):
		}
	}
}

// Step is one look for a request, and a fetch when it's time (Run's loop;
// Known loads the state first).
func (m *Manager) Step(ctx context.Context) {
	req, err := m.request(ctx)
	if err != nil {
		m.logf("the request: %v", err)
	}
	if req != nil && req.RequestedAt > m.state.Handled {
		m.handle(ctx, req)
	}
	if len(m.state.Cameras) > 0 && m.now().Sub(m.lastFetch) >= m.Every {
		m.fetch(ctx)
	}
}

// request is the app's request, opened; nil when there's none.
func (m *Manager) request(ctx context.Context) (*Request, error) {
	tmp, err := os.MkdirTemp(m.Dir, m.name()+"-req-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	file := filepath.Join(tmp, "request.json")
	if err := m.Store.Get(ctx, m.requestKey(), file); err != nil {
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
	if err := seal.Open(&plain, sealed, m.Key); err != nil {
		return nil, fmt.Errorf("the request doesn't open with this device's key: %w", err)
	}
	req := &Request{}
	if err := json.Unmarshal(plain.Bytes(), req); err != nil {
		return nil, err
	}
	return req, nil
}

// handle answers one request: a camera added or removed.
func (m *Manager) handle(ctx context.Context, req *Request) {
	defer func() {
		m.state.Handled = req.RequestedAt
		if err := m.save(); err != nil {
			m.logf("saving: %v", err)
		}
		// The password goes from the cloud once it's been used.
		if err := m.Store.Delete(ctx, m.requestKey()); err != nil {
			m.logf("deleting the request: %v", err)
		}
	}()
	switch {
	case req.Remove != "":
		if c, ok := m.state.Cameras[req.Remove]; ok {
			delete(m.state.Cameras, req.Remove)
			m.logf("%q removed; its device and events stay", c.Name)
			m.save()
			m.announce(ctx)
		}
		m.setStatus(ctx, Status{State: StateOK, RequestedAt: req.RequestedAt})
	case req.Add != nil:
		m.add(ctx, req)
	}
}

func (m *Manager) add(ctx context.Context, req *Request) {
	a := *req.Add
	name := strings.TrimSpace(a.Name)
	if name == "" {
		name = "Camera"
	}
	base, err := m.Kind.Base(a)
	if err != nil {
		m.fail(ctx, req, err.Error())
		return
	}
	if a.Channel < 0 {
		a.Channel = 0
	}
	m.setStatus(ctx, Status{State: StateChecking, RequestedAt: req.RequestedAt})
	c := Camera{Name: name, Base: base, Username: strings.TrimSpace(a.Username), Password: a.Password, Channel: a.Channel}
	// The camera's certificate, pinned now: it signs its own.
	if strings.HasPrefix(base, "https://") {
		pin, err := fingerprint(ctx, base)
		if err != nil {
			m.fail(ctx, req, "couldn't reach "+a.Address+": "+err.Error())
			return
		}
		c.Pin = pin
	}
	s, err := m.Kind.Login(ctx, &Conn{Camera: c})
	if err != nil {
		if !errors.Is(err, ErrRefused) {
			err = errors.New("couldn't reach " + a.Address + ": " + err.Error())
		}
		m.fail(ctx, req, err.Error())
		return
	}
	defer s.Close()
	// The same camera again (its address and channel): its device stays,
	// the rest is new.
	for id, old := range m.state.Cameras {
		if old.Base == base && old.Channel == c.Channel {
			c.DeviceID, c.Since = id, old.Since
		}
	}
	if c.DeviceID == "" {
		c.DeviceID = m.NewDevice()
		// The first fetch goes back Backfill (in the camera's clock).
		now, ok := s.Now(ctx)
		if !ok {
			now = m.now()
		}
		c.Since = now.Add(-m.Backfill).Unix()
		m.logf("%q (%s) is device %s", name, base, c.DeviceID)
	}
	m.state.Cameras[c.DeviceID] = c
	delete(m.errs, c.DeviceID)
	m.save()
	m.announce(ctx)
	m.setStatus(ctx, Status{State: StateOK, RequestedAt: req.RequestedAt})
	m.lastFetch = time.Time{}
}

func (m *Manager) fail(ctx context.Context, req *Request, why string) {
	m.logf("%s", why)
	m.setStatus(ctx, Status{State: StateError, Error: why, RequestedAt: req.RequestedAt})
}

func (m *Manager) announce(ctx context.Context) {
	if m.Cameras == nil {
		return
	}
	if err := m.Cameras(ctx, m.cameraList()); err != nil {
		m.logf("registering the cameras: %v", err)
	}
}

// BaseOf is a camera's API for an address the app gave: an IP address or
// host name (https://, or with plain, plain http:// on port plainPort), or a
// full http(s) URL. A password needs HTTPS: it isn't sent in the clear.
func BaseOf(address string, plain bool, plainPort string, password bool) (string, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return "", errors.New("the camera's address is missing")
	}
	if !strings.Contains(address, "://") {
		if plain {
			if _, _, err := net.SplitHostPort(address); err != nil && plainPort != "" {
				address += ":" + plainPort
			}
			address = "http://" + address
		} else {
			address = "https://" + address
		}
	}
	u, err := url.Parse(address)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || u.Path != "" && u.Path != "/" {
		return "", fmt.Errorf("%q isn't a camera's address (an IP address, or http(s)://host[:port])", address)
	}
	if password && u.Scheme == "http" {
		return "", errors.New("a password needs https://: it isn't sent in the clear")
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

// Conn talks to a camera: over HTTPS only to the certificate pinned.
type Conn struct {
	Camera Camera
	client *http.Client
}

// Client is the camera's HTTP client.
func (c *Conn) Client() *http.Client {
	if c.client != nil {
		return c.client
	}
	tr := &http.Transport{
		DialContext:           (&net.Dialer{Timeout: 10 * time.Second}).DialContext,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
	}
	if pin := c.Camera.Pin; pin != "" {
		tr.TLSClientConfig = &tls.Config{
			// The camera signs its own certificate: it's checked against the
			// one pinned when it was added instead.
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
	c.client = &http.Client{Transport: tr}
	return c.client
}

// Do sends req (to the camera's API, Base + its path); an answer that isn't
// 200 is an error (401: ErrRefused).
func (c *Conn) Do(req *http.Request) (*http.Response, error) {
	resp, err := c.Client().Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		if resp.StatusCode == http.StatusUnauthorized {
			return nil, ErrRefused
		}
		return nil, fmt.Errorf("%s: %s", req.URL.Path, resp.Status)
	}
	return resp, nil
}

// JSON decodes resp's body (at most 8 MB) into v, and closes it.
func JSON(resp *http.Response, v any) error {
	defer resp.Body.Close()
	return json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(v)
}

// skew is how far the camera's clock is ahead of UTC, to the quarter hour
// (its time zone, mostly).
func (m *Manager) skew(ctx context.Context, s Session) time.Duration {
	at, ok := s.Now(ctx)
	if !ok {
		return 0
	}
	return at.Sub(m.now()).Round(15 * time.Minute)
}

// fetch downloads each camera's new videos and hands them over.
func (m *Manager) fetch(ctx context.Context) {
	m.lastFetch = m.now()
	for _, c := range m.cameraList() {
		if err := m.fetchCamera(ctx, c); err != nil {
			if m.errs[c.DeviceID] != err.Error() {
				m.logf("%q: %v", c.Name, err)
			}
			m.errs[c.DeviceID] = err.Error()
		} else {
			delete(m.errs, c.DeviceID)
			m.fetched[c.DeviceID] = m.now().UnixMilli()
		}
	}
	if err := m.save(); err != nil {
		m.logf("saving: %v", err)
	}
	m.setStatus(ctx, Status{State: StateOK})
}

func (m *Manager) fetchCamera(ctx context.Context, c Camera) error {
	s, err := m.Kind.Login(ctx, &Conn{Camera: c})
	if err != nil {
		return err
	}
	defer s.Close()
	videos, err := s.Videos(ctx, c.Since)
	if err != nil {
		return err
	}
	var skew *time.Duration
	for _, v := range videos {
		if v.Created <= c.Since {
			continue
		}
		if skew == nil {
			d := m.skew(ctx, s)
			skew = &d
		}
		start := time.Unix(v.Created, 0).Add(-*skew).UTC()
		if err := m.fetchVideo(ctx, s, c, v, start); err != nil {
			return fmt.Errorf("%s: %w", v.ID, err)
		}
		// Where it got to, kept at once: a restart doesn't fetch it again.
		c.Since = v.Created
		if cur, ok := m.state.Cameras[c.DeviceID]; ok {
			cur.Since = c.Since
			m.state.Cameras[c.DeviceID] = cur
			m.save()
		}
	}
	return nil
}

func (m *Manager) fetchVideo(ctx context.Context, s Session, c Camera, v Video, start time.Time) error {
	if m.MaxBytes > 0 && v.Size > m.MaxBytes {
		m.logf("%q: %s skipped, %d MB is too big", c.Name, v.ID, v.Size>>20)
		return nil
	}
	dir := filepath.Join(m.Dir, m.name()+"-incoming", c.DeviceID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	out := filepath.Join(dir, "rec-"+m.name()+"-"+start.Format("20060102T150405")+".mp4")
	body, err := s.Open(ctx, v)
	if err != nil {
		return err
	}
	defer body.Close()
	tmp, err := os.OpenFile(out+".part", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	var r io.Reader = body
	if m.MaxBytes > 0 {
		r = io.LimitReader(body, m.MaxBytes+1)
	}
	n, err := io.Copy(tmp, r)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil && m.MaxBytes > 0 && n > m.MaxBytes {
		os.Remove(out + ".part")
		m.logf("%q: %s skipped, more than %d MB", c.Name, v.ID, m.MaxBytes>>20)
		return nil
	}
	if err != nil {
		os.Remove(out + ".part")
		return err
	}
	if err := os.Rename(out+".part", out); err != nil {
		return err
	}
	m.logf("%q: %s fetched (%d MB)", c.Name, v.ID, n>>20)
	return m.Clip(ctx, c, out)
}

// setStatus publishes the status, sealed, with the cameras.
func (m *Manager) setStatus(ctx context.Context, s Status) {
	if s.RequestedAt == 0 {
		s.RequestedAt = m.state.Handled
	}
	for _, c := range m.cameraList() {
		s.Cameras = append(s.Cameras, StatusCamera{
			Name: c.Name, DeviceID: c.DeviceID, Address: c.Base, Channel: c.Channel,
			LastFetch: m.fetched[c.DeviceID], Error: m.errs[c.DeviceID],
		})
	}
	if s.State == StateOK && len(s.Cameras) == 0 {
		s.State = StateOff
	}
	s.UpdatedAt = m.now().UnixMilli()
	plain := filepath.Join(m.Dir, m.name()+"-status.json")
	if err := writeFile(plain, mustJSON(s)); err != nil {
		m.logf("status: %v", err)
		return
	}
	defer os.Remove(plain)
	sealed := plain + ".sealed"
	if err := seal.File(plain, sealed, m.Key, m.DeviceID); err != nil {
		m.logf("status: %v", err)
		return
	}
	defer os.Remove(sealed)
	if err := m.Store.Put(ctx, sealed, m.statusKey(), "application/octet-stream"); err != nil {
		m.logf("status: %v", err)
	}
}
