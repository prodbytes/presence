// Package blink makes a Blink account's cameras Presence devices
// (specs/streamer.md, "Blink cameras"): one streamer of the profile, the one
// the app's Settings pick, logs in to Blink with blinkpy (the
// presence-blink.py helper), and every camera becomes a device of its own,
// with an ID made here, whose clips go through the same chunk pipeline as
// the Pi's own recordings.
//
// The app and this streamer talk through the profile's folder, sealed with
// this streamer's media key (only the profile's devices hold it):
//
//   - devices/<streamer>/blink.json, the app's request: {"email",
//     "password", "pin", "disconnect", "requestedAt"}. Deleted once
//     handled, so the password doesn't stay in the cloud.
//   - devices/<streamer>/blink-status.json, this streamer's answer:
//     {"state", "error", "account", "cameras": [{"name", "deviceId"}],
//     "lastFetch", "requestedAt", "updatedAt"}.
//
// Here, in the state folder: blink-token.json (blinkpy's token, mode 600:
// never the password) and blink-state.json (the cameras' device IDs, and
// where fetching got to).
package blink

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// States the status says.
const (
	StateOff        = "off"
	StateInstalling = "installing"
	StateLoggingIn  = "logging-in"
	StatePIN        = "pin-required"
	StateConnected  = "connected"
	StateError      = "error"
)

// Store is the profile's folder in the bucket.
type Store interface {
	Put(ctx context.Context, path, key, contentType string) error
	Get(ctx context.Context, key, path string) error
	Delete(ctx context.Context, key string) error
}

// Request is the app's (devices/<streamer>/blink.json).
type Request struct {
	Email       string `json:"email,omitempty"`
	Password    string `json:"password,omitempty"`
	PIN         string `json:"pin,omitempty"`
	Disconnect  bool   `json:"disconnect,omitempty"`
	RequestedAt int64  `json:"requestedAt"`
}

// Camera is a Blink camera and the Presence device it is.
type Camera struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	DeviceID string `json:"deviceId"`
}

// Status is this streamer's answer (devices/<streamer>/blink-status.json).
type Status struct {
	State       string         `json:"state"`
	Error       string         `json:"error,omitempty"`
	Account     string         `json:"account,omitempty"`
	Cameras     []StatusCamera `json:"cameras,omitempty"`
	LastFetch   int64          `json:"lastFetch,omitempty"`
	RequestedAt int64          `json:"requestedAt,omitempty"`
	UpdatedAt   int64          `json:"updatedAt"`
}

// StatusCamera is a camera as the app lists it.
type StatusCamera struct {
	Name     string `json:"name"`
	DeviceID string `json:"deviceId"`
}

// saved is blink-state.json.
type saved struct {
	Account string            `json:"account,omitempty"`
	Cameras map[string]Camera `json:"cameras,omitempty"`
	// Since is where fetching got to, in epoch seconds.
	Since int64 `json:"since,omitempty"`
	// Handled is the requestedAt of the last request handled.
	Handled int64 `json:"handled,omitempty"`
	// Refused: Blink refused the saved login; no fetching until a new one.
	Refused bool `json:"refused,omitempty"`
}

// Blink fetches a Blink account's clips for its cameras' devices.
type Blink struct {
	// Dir is the state folder.
	Dir string
	// DeviceID is this streamer's; Key its media key.
	DeviceID string
	Key      []byte
	Store    Store
	// Helper makes the command running presence-blink.py with args.
	Helper func(ctx context.Context, args ...string) *exec.Cmd
	// Ensure makes blinkpy ready to run (installs it the first time).
	Ensure func(ctx context.Context) error
	// NewDevice makes a camera's device ID.
	NewDevice func() string
	// Cameras is told the cameras' device IDs whenever they change, so they
	// join the profile's devices and get their pipelines.
	Cameras func(ctx context.Context, cameras []Camera) error
	// Clip hands a camera's fetched clip to its pipeline (it's moved).
	Clip func(ctx context.Context, camera Camera, file string) error
	// Poll is how often the request is looked for; Every how often clips
	// are fetched; Backfill how far back the first fetch goes.
	Poll, Every, Backfill time.Duration
	// PINWait is how long a PIN is waited for.
	PINWait time.Duration
	Now     func() time.Time
	Logf    func(string, ...any)

	state     saved
	lastFetch time.Time
	status    Status
}

func (b *Blink) statePath() string { return filepath.Join(b.Dir, "blink-state.json") }

// TokenPath is blinkpy's token's file.
func (b *Blink) TokenPath() string { return filepath.Join(b.Dir, "blink-token.json") }

func (b *Blink) requestKey() string { return "devices/" + b.DeviceID + "/blink.json" }
func (b *Blink) statusKey() string  { return "devices/" + b.DeviceID + "/blink-status.json" }

func (b *Blink) now() time.Time {
	if b.Now != nil {
		return b.Now()
	}
	return time.Now()
}

func (b *Blink) load() {
	b.state = saved{}
	if data, err := os.ReadFile(b.statePath()); err == nil {
		json.Unmarshal(data, &b.state)
	}
	if b.state.Cameras == nil {
		b.state.Cameras = map[string]Camera{}
	}
}

func (b *Blink) save() error { return writeFile(b.statePath(), mustJSON(b.state)) }

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

// Known returns the cameras saved (their device IDs), for the start.
func (b *Blink) Known() []Camera {
	b.load()
	return b.cameraList()
}

func (b *Blink) cameraList() []Camera {
	out := make([]Camera, 0, len(b.state.Cameras))
	for _, c := range b.state.Cameras {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

func (b *Blink) connected() bool {
	_, err := os.Stat(b.TokenPath())
	return err == nil && !b.state.Refused
}

// Run looks for the app's requests and fetches clips until ctx ends.
func (b *Blink) Run(ctx context.Context) error {
	b.load()
	if b.connected() {
		b.setStatus(ctx, Status{State: StateConnected})
	}
	for {
		b.step(ctx)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(b.Poll):
		}
	}
}

// step is one look for a request, and a fetch when it's time.
func (b *Blink) step(ctx context.Context) {
	req, err := b.request(ctx)
	if err != nil {
		b.Logf("blink: the request: %v", err)
	}
	if req != nil && req.RequestedAt > b.state.Handled {
		b.handle(ctx, req)
	}
	if b.connected() && b.now().Sub(b.lastFetch) >= b.Every {
		b.fetch(ctx)
	}
}

// request is the app's request, opened; nil when there's none.
func (b *Blink) request(ctx context.Context) (*Request, error) {
	tmp, err := os.MkdirTemp(b.Dir, "blink-req-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)
	path := filepath.Join(tmp, "blink.json")
	if err := b.Store.Get(ctx, b.requestKey(), path); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	sealed, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer sealed.Close()
	var plain bytes.Buffer
	if err := seal.Open(&plain, sealed, b.Key); err != nil {
		return nil, fmt.Errorf("the request doesn't open with this device's key: %w", err)
	}
	req := &Request{}
	if err := json.Unmarshal(plain.Bytes(), req); err != nil {
		return nil, err
	}
	return req, nil
}

// handle answers one request: a disconnect, or a login.
func (b *Blink) handle(ctx context.Context, req *Request) {
	defer func() {
		b.state.Handled = req.RequestedAt
		if err := b.save(); err != nil {
			b.Logf("blink: saving: %v", err)
		}
		// The password goes from the cloud once it's been used.
		if err := b.Store.Delete(ctx, b.requestKey()); err != nil {
			b.Logf("blink: deleting the request: %v", err)
		}
	}()
	if req.Disconnect {
		os.Remove(b.TokenPath())
		b.state.Account, b.state.Refused = "", false
		b.Logf("blink: disconnected; its cameras' devices stay")
		b.setStatus(ctx, Status{State: StateOff, RequestedAt: req.RequestedAt})
		return
	}
	b.login(ctx, req)
}

func (b *Blink) login(ctx context.Context, req *Request) {
	b.setStatus(ctx, Status{State: StateInstalling, RequestedAt: req.RequestedAt})
	if err := b.Ensure(ctx); err != nil {
		b.fail(ctx, req, "blinkpy couldn't be installed: "+err.Error())
		return
	}
	b.setStatus(ctx, Status{State: StateLoggingIn, RequestedAt: req.RequestedAt})
	cmd := b.Helper(ctx, "login", "--token", b.TokenPath())
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		b.fail(ctx, req, "the Blink helper didn't start: "+err.Error())
		return
	}
	defer cmd.Wait()
	defer stdin.Close()
	io.WriteString(stdin, string(mustJSON(map[string]string{"email": req.Email, "password": req.Password}))+"\n")
	lines := bufio.NewScanner(stdout)
	for lines.Scan() {
		var answer struct {
			State   string `json:"state"`
			Error   string `json:"error"`
			Cameras []struct {
				ID   string `json:"id"`
				Name string `json:"name"`
			} `json:"cameras"`
		}
		if json.Unmarshal(lines.Bytes(), &answer) != nil {
			continue
		}
		switch answer.State {
		case StatePIN:
			b.setStatus(ctx, Status{State: StatePIN, Account: req.Email, RequestedAt: req.RequestedAt})
			pin := b.waitPIN(ctx, req)
			io.WriteString(stdin, string(mustJSON(map[string]string{"pin": pin}))+"\n")
		case "ok":
			b.state.Account, b.state.Refused = req.Email, false
			if b.state.Since == 0 {
				b.state.Since = b.now().Add(-b.Backfill).Unix()
			}
			for _, c := range answer.Cameras {
				b.camera(c.ID, c.Name)
			}
			b.save()
			b.announce(ctx)
			b.Logf("blink: logged in as %s, %d camera(s)", req.Email, len(answer.Cameras))
			b.setStatus(ctx, Status{State: StateConnected, RequestedAt: req.RequestedAt})
			b.lastFetch = time.Time{}
			return
		case StateError:
			b.fail(ctx, req, answer.Error)
			return
		}
	}
	b.fail(ctx, req, "the Blink helper stopped: "+strings.TrimSpace(lastLine(stderr.String())))
}

// waitPIN waits for the app's request to carry a PIN (the same request,
// written again with it); "" if none comes in time.
func (b *Blink) waitPIN(ctx context.Context, req *Request) string {
	deadline := b.now().Add(b.PINWait)
	for b.now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ""
		case <-time.After(b.Poll):
		}
		next, err := b.request(ctx)
		if err == nil && next != nil && next.PIN != "" && next.RequestedAt >= req.RequestedAt {
			return next.PIN
		}
	}
	return ""
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return lines[len(lines)-1]
}

func (b *Blink) fail(ctx context.Context, req *Request, why string) {
	b.Logf("blink: login failed: %s", why)
	b.setStatus(ctx, Status{State: StateError, Error: why, Account: req.Email, RequestedAt: req.RequestedAt})
}

// camera is Blink camera id's device, made the first time it's seen.
func (b *Blink) camera(id, name string) (Camera, bool) {
	if c, ok := b.state.Cameras[id]; ok {
		if name != "" && c.Name != name {
			c.Name = name
			b.state.Cameras[id] = c
		}
		return c, false
	}
	c := Camera{ID: id, Name: name, DeviceID: b.NewDevice()}
	b.state.Cameras[id] = c
	b.Logf("blink: camera %q is device %s", name, c.DeviceID)
	return c, true
}

func (b *Blink) announce(ctx context.Context) {
	if b.Cameras == nil {
		return
	}
	if err := b.Cameras(ctx, b.cameraList()); err != nil {
		b.Logf("blink: registering the cameras: %v", err)
	}
}

// fetch downloads the clips since the last fetch and hands them over.
func (b *Blink) fetch(ctx context.Context) {
	b.lastFetch = b.now()
	if err := b.Ensure(ctx); err != nil {
		b.Logf("blink: blinkpy: %v", err)
		return
	}
	out := filepath.Join(b.Dir, "blink-incoming")
	os.MkdirAll(out, 0o700)
	cmd := b.Helper(ctx, "fetch", "--token", b.TokenPath(), "--since", fmt.Sprint(b.state.Since), "--out", out)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	added := false
	for _, line := range strings.Split(stdout.String(), "\n") {
		var answer struct {
			State  string `json:"state"`
			Error  string `json:"error"`
			Latest int64  `json:"latest"`
			Clip   *struct {
				Camera string `json:"camera"`
				Name   string `json:"name"`
				File   string `json:"file"`
			} `json:"clip"`
		}
		if json.Unmarshal([]byte(line), &answer) != nil {
			continue
		}
		if c := answer.Clip; c != nil {
			camera, isNew := b.camera(c.Camera, c.Name)
			added = added || isNew
			if added {
				b.save()
				b.announce(ctx)
				added = false
			}
			if err := b.Clip(ctx, camera, c.File); err != nil {
				b.Logf("blink: clip %s: %v", c.File, err)
			}
			continue
		}
		if answer.State == "ok" && answer.Latest >= b.state.Since {
			b.state.Since = answer.Latest + 1
		}
		if answer.State == StateError {
			b.Logf("blink: fetching: %s", answer.Error)
		}
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 2 {
		// The token's no good: wait for a new login from the app.
		b.state.Refused = true
		b.setStatus(ctx, Status{State: StateError, Error: "Blink refused the saved login: log in again"})
	} else if err != nil {
		b.Logf("blink: fetching: %v %s", err, strings.TrimSpace(lastLine(stderr.String())))
	} else {
		b.setStatus(ctx, Status{State: StateConnected, LastFetch: b.now().UnixMilli()})
	}
	if err := b.save(); err != nil {
		b.Logf("blink: saving: %v", err)
	}
}

// setStatus publishes the status, sealed, with the cameras and account.
func (b *Blink) setStatus(ctx context.Context, s Status) {
	if s.LastFetch == 0 {
		s.LastFetch = b.status.LastFetch
	}
	if s.Account == "" {
		s.Account = b.state.Account
	}
	if s.RequestedAt == 0 {
		s.RequestedAt = b.state.Handled
	}
	for _, c := range b.cameraList() {
		s.Cameras = append(s.Cameras, StatusCamera{Name: c.Name, DeviceID: c.DeviceID})
	}
	s.UpdatedAt = b.now().UnixMilli()
	b.status = s
	plain := filepath.Join(b.Dir, "blink-status.json")
	if err := writeFile(plain, mustJSON(s)); err != nil {
		b.Logf("blink: status: %v", err)
		return
	}
	defer os.Remove(plain)
	sealed := plain + ".sealed"
	if err := seal.File(plain, sealed, b.Key, b.DeviceID); err != nil {
		b.Logf("blink: status: %v", err)
		return
	}
	defer os.Remove(sealed)
	if err := b.Store.Put(ctx, sealed, b.statusKey(), "application/octet-stream"); err != nil {
		b.Logf("blink: status: %v", err)
	}
}
