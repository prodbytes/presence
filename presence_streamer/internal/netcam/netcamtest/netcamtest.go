// Package netcamtest helps test the netcam kinds: the profile's folder in
// memory, and a Manager on it whose clock the test moves.
package netcamtest

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/netcam"
	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// Streamer is the streamer's device ID; Key its media key.
const Streamer = "calm_quiet_otter"

var Key = bytes.Repeat([]byte{7}, 32)

// Store is the profile's folder, in memory.
type Store struct {
	mu      sync.Mutex
	objects map[string][]byte
}

func (m *Store) Put(_ context.Context, path, key, _ string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.objects[key] = data
	return nil
}

func (m *Store) Get(_ context.Context, key, path string) error {
	m.mu.Lock()
	data, ok := m.objects[key]
	m.mu.Unlock()
	if !ok {
		return fmt.Errorf("%s: %w", key, os.ErrNotExist)
	}
	return os.WriteFile(path, data, 0o600)
}

func (m *Store) Delete(_ context.Context, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.objects, key)
	return nil
}

// Has says whether key is there.
func (m *Store) Has(key string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.objects[key]
	return ok
}

// Holds says which object holds s in the clear ("" for none).
func (m *Store) Holds(s string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, v := range m.objects {
		if bytes.Contains(v, []byte(s)) {
			return k
		}
	}
	return ""
}

// Clip is a video handed to a camera's pipeline.
type Clip struct{ Device, Name, Content string }

// Harness is a Manager of kind on an in-memory folder.
type Harness struct {
	M          *netcam.Manager
	Store      *Store
	Clips      []Clip
	Registered [][]netcam.Camera
	// Clock is the streamer's; Tick moves it past the fetching interval.
	Clock time.Time
}

// New is a Manager of kind, its clock at now, its device IDs <kind>_cam_<n>.
func New(t *testing.T, kind netcam.Kind, now time.Time) *Harness {
	h := &Harness{Store: &Store{objects: map[string][]byte{}}, Clock: now}
	h.M = h.manager(t, kind, t.TempDir())
	return h
}

// Restart is a new Manager on the same folders, as after a restart.
func (h *Harness) Restart(t *testing.T) {
	h.M = h.manager(t, h.M.Kind, h.M.Dir)
}

func (h *Harness) manager(t *testing.T, kind netcam.Kind, dir string) *netcam.Manager {
	n := 0
	m := &netcam.Manager{
		Kind: kind, Dir: dir, DeviceID: Streamer, Key: Key, Store: h.Store,
		NewDevice: func() string { n++; return fmt.Sprintf("%s_cam_%d", kind.Name(), n) },
		Cameras: func(_ context.Context, cameras []netcam.Camera) error {
			h.Registered = append(h.Registered, cameras)
			return nil
		},
		Clip: func(_ context.Context, c netcam.Camera, f string) error {
			data, _ := os.ReadFile(f)
			h.Clips = append(h.Clips, Clip{c.DeviceID, filepath.Base(f), string(data)})
			return os.Remove(f)
		},
		Poll: time.Millisecond, Every: 2 * time.Minute, Backfill: 24 * time.Hour,
		Now:  func() time.Time { return h.Clock },
		Logf: t.Logf,
	}
	m.Known()
	return m
}

// Request writes the app's request, sealed with the streamer's key, and
// steps the Manager.
func (h *Harness) Request(t *testing.T, req netcam.Request) {
	var sealed bytes.Buffer
	data, _ := json.Marshal(req)
	if err := seal.Seal(&sealed, bytes.NewReader(data), Key, Streamer, nil); err != nil {
		t.Fatal(err)
	}
	h.Store.mu.Lock()
	h.Store.objects[h.RequestKey()] = sealed.Bytes()
	h.Store.mu.Unlock()
	h.M.Step(context.Background())
}

// Tick moves the clock past the fetching interval and steps the Manager.
func (h *Harness) Tick() {
	h.Clock = h.Clock.Add(h.M.Every)
	h.M.Step(context.Background())
}

// RequestKey is where the app's request goes.
func (h *Harness) RequestKey() string {
	return "devices/" + Streamer + "/" + h.M.Kind.Name() + ".json"
}

// Status opens the streamer's status.
func (h *Harness) Status(t *testing.T) netcam.Status {
	h.Store.mu.Lock()
	sealed := h.Store.objects["devices/"+Streamer+"/"+h.M.Kind.Name()+"-status.json"]
	h.Store.mu.Unlock()
	var plain bytes.Buffer
	if err := seal.Open(&plain, bytes.NewReader(sealed), Key); err != nil {
		t.Fatal(err)
	}
	var s netcam.Status
	json.Unmarshal(plain.Bytes(), &s)
	return s
}

// Camera is the camera saved with device ID id.
func (h *Harness) Camera(id string) (netcam.Camera, bool) {
	for _, c := range h.cameras() {
		if c.DeviceID == id {
			return c, true
		}
	}
	return netcam.Camera{}, false
}

// Cameras are the cameras saved.
func (h *Harness) Cameras() []netcam.Camera { return h.cameras() }

func (h *Harness) cameras() []netcam.Camera {
	var s struct {
		Cameras map[string]netcam.Camera `json:"cameras"`
	}
	data, _ := os.ReadFile(filepath.Join(h.M.Dir, h.M.Kind.Name()+"-state.json"))
	json.Unmarshal(data, &s)
	out := []netcam.Camera{}
	for _, c := range s.Cameras {
		out = append(out, c)
	}
	return out
}

// Edit changes the saved camera id (then restarts, so it's read again).
func (h *Harness) Edit(t *testing.T, id string, edit func(*netcam.Camera)) {
	path := filepath.Join(h.M.Dir, h.M.Kind.Name()+"-state.json")
	var s map[string]json.RawMessage
	data, _ := os.ReadFile(path)
	json.Unmarshal(data, &s)
	var cameras map[string]netcam.Camera
	json.Unmarshal(s["cameras"], &cameras)
	c := cameras[id]
	edit(&c)
	cameras[id] = c
	s["cameras"], _ = json.Marshal(cameras)
	data, _ = json.Marshal(s)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	h.Restart(t)
}
