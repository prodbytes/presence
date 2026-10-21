package blink

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
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
	m.objects["devices/calm_quiet_otter/blink.json"] = sealed.Bytes()
	m.mu.Unlock()
}

// status opens the streamer's status.
func (m *memStore) status(t *testing.T) Status {
	m.mu.Lock()
	sealed := m.objects["devices/calm_quiet_otter/blink-status.json"]
	m.mu.Unlock()
	var plain bytes.Buffer
	if err := seal.Open(&plain, bytes.NewReader(sealed), key); err != nil {
		t.Fatal(err)
	}
	var s Status
	json.Unmarshal(plain.Bytes(), &s)
	return s
}

// fakeHelper is presence-blink.py as a shell script: login asks for a PIN
// (and checks it's 123456), fetch hands out two clips of two cameras, or
// exits 2 when told the token's refused.
const fakeHelper = `#!/bin/sh
cmd=$1; shift
case "$cmd" in
login)
  read creds
  case "$creds" in *'"password":"secret"'*) ;; *) echo '{"state":"error","error":"bad password"}'; exit 2;; esac
  echo '{"state":"pin-required"}'
  read pin
  case "$pin" in *123456*) ;; *) echo '{"state":"error","error":"bad PIN"}'; exit 2;; esac
  echo '{}' > "$2"
  echo '{"state":"ok","cameras":[{"id":"11","name":"Porch"},{"id":"22","name":"Garden"}]}'
  ;;
fetch)
  [ -f "$REFUSE" ] && { echo '{"state":"error","error":"refused"}'; exit 2; }
  echo "$*" > "$(dirname "$REFUSE")/fetch-args"
  out=$6
  mkdir -p "$out/11" "$out/33"
  # As the helper: a clip downloaded already is skipped.
  [ -f "$out/11/rec-blink-20261014T120000.mp4" ] || {
    echo video > "$out/11/rec-blink-20261014T120000.mp4"
    echo '{"clip":{"camera":"11","name":"Porch","file":"'$out'/11/rec-blink-20261014T120000.mp4"}}'
  }
  [ -f "$out/33/rec-blink-20261014T120100.mp4" ] || {
    echo video > "$out/33/rec-blink-20261014T120100.mp4"
    echo '{"clip":{"camera":"33","name":"Shed","file":"'$out'/33/rec-blink-20261014T120100.mp4"}}'
  }
  echo '{"state":"ok","latest":1791979260}'
  ;;
esac
`

func newBlink(t *testing.T) (*Blink, *memStore, *[]string, *[]Camera) {
	dir := t.TempDir()
	helper := filepath.Join(dir, "presence-blink.sh")
	os.WriteFile(helper, []byte(fakeHelper), 0o755)
	store := &memStore{objects: map[string][]byte{}}
	var clips []string
	var registered []Camera
	n := 0
	// The clock starts an hour after the fake clips (2026-10-14 12:00 UTC),
	// inside the backfill, and runs at real speed for the PIN wait.
	start, epoch := time.Now(), time.Date(2026, 10, 14, 13, 0, 0, 0, time.UTC)
	b := &Blink{
		Now: func() time.Time { return epoch.Add(time.Since(start)) },
		Dir: dir, DeviceID: "calm_quiet_otter", Key: key, Store: store,
		Helper: func(ctx context.Context, args ...string) *exec.Cmd {
			cmd := exec.CommandContext(ctx, helper, args...)
			cmd.Env = append(os.Environ(), "REFUSE="+filepath.Join(dir, "refuse"))
			return cmd
		},
		Ensure:    func(context.Context) error { return nil },
		NewDevice: func() string { n++; return fmt.Sprintf("blink_camera_%d", n) },
		Cameras: func(_ context.Context, cs []Camera) error {
			registered = cs
			return nil
		},
		Clip: func(_ context.Context, c Camera, file string) error {
			clips = append(clips, c.DeviceID+" "+filepath.Base(file))
			// Moved to the camera's spool.
			return os.Remove(file)
		},
		Poll: 10 * time.Millisecond, Every: time.Hour, Backfill: 24 * time.Hour, PINWait: 5 * time.Second,
		Logf: t.Logf,
	}
	b.load()
	return b, store, &clips, &registered
}

// login puts the app's login request, requested at at, and gives the PIN
// once the status asks for it, watching as long as the streamer waits for
// it (the helper can be slow to ask on a loaded machine).
func login(t *testing.T, b *Blink, store *memStore, at int64) {
	store.put(t, Request{Email: "a@b.c", Password: "secret", RequestedAt: at})
	go func() {
		for deadline := time.Now().Add(b.PINWait + 5*time.Second); time.Now().Before(deadline); {
			time.Sleep(5 * time.Millisecond)
			store.mu.Lock()
			_, has := store.objects["devices/calm_quiet_otter/blink-status.json"]
			store.mu.Unlock()
			if has {
				if s := store.status(t); s.State == StatePIN && s.RequestedAt == at {
					store.put(t, Request{Email: "a@b.c", Password: "secret", PIN: "123456", RequestedAt: at})
					return
				}
			}
		}
	}()
}

func TestLoginWithAPINFromTheApp(t *testing.T) {
	b, store, clips, registered := newBlink(t)
	ctx := context.Background()
	login(t, b, store, 1)
	b.step(ctx)
	s := store.status(t)
	if s.State != StateConnected || s.Account != "a@b.c" {
		t.Fatalf("status %+v", s)
	}
	// The login's two, by name, and the one the first fetch found.
	if len(s.Cameras) != 3 || s.Cameras[0].Name != "Garden" || s.Cameras[1].DeviceID != "blink_camera_1" ||
		s.Cameras[2].Name != "Shed" {
		t.Fatalf("cameras %+v", s.Cameras)
	}
	if _, ok := store.objects["devices/calm_quiet_otter/blink.json"]; ok {
		t.Fatal("the request (with the password) is still in the cloud")
	}
	if data, _ := os.ReadFile(b.TokenPath()); strings.Contains(string(data), "secret") {
		t.Fatal("the password is in the token file")
	}
	// Fetched: each clip to its camera's device; a new camera gets one.
	if len(*clips) != 2 || (*clips)[0] != "blink_camera_1 rec-blink-20261014T120000.mp4" ||
		(*clips)[1] != "blink_camera_3 rec-blink-20261014T120100.mp4" {
		t.Fatalf("clips %v", *clips)
	}
	if len(*registered) != 3 {
		t.Fatalf("the shed's camera wasn't registered: %+v", *registered)
	}
	if b.state.Since != 1791979261 {
		t.Fatalf("since %d", b.state.Since)
	}
	// The same request isn't handled twice.
	store.put(t, Request{Email: "a@b.c", Password: "secret", RequestedAt: 1})
	b.step(ctx)
	if store.status(t).State != StateConnected {
		t.Fatal("handled again")
	}
}

func TestAWrongPasswordSaysSoAndKeepsNothing(t *testing.T) {
	b, store, _, _ := newBlink(t)
	store.put(t, Request{Email: "a@b.c", Password: "wrong", RequestedAt: 5})
	b.step(context.Background())
	s := store.status(t)
	if s.State != StateError || s.Error != "bad password" || s.RequestedAt != 5 {
		t.Fatalf("status %+v", s)
	}
	if _, err := os.Stat(b.TokenPath()); err == nil {
		t.Fatal("a token was kept")
	}
	if _, ok := store.objects["devices/calm_quiet_otter/blink.json"]; ok {
		t.Fatal("the request is still in the cloud")
	}
}

func TestARefusedTokenStopsFetchingAndDisconnectForgetsIt(t *testing.T) {
	b, store, clips, _ := newBlink(t)
	os.WriteFile(b.TokenPath(), []byte("{}"), 0o600)
	os.WriteFile(filepath.Join(b.Dir, "refuse"), nil, 0o600)
	b.step(context.Background())
	if s := store.status(t); s.State != StateError || !strings.Contains(s.Error, "log in again") {
		t.Fatalf("status %+v", s)
	}
	if len(*clips) != 0 || b.connected() {
		t.Fatal("still fetching")
	}
	store.put(t, Request{Disconnect: true, RequestedAt: 9})
	b.step(context.Background())
	if s := store.status(t); s.State != StateOff {
		t.Fatalf("status %+v", s)
	}
	if _, err := os.Stat(b.TokenPath()); err == nil {
		t.Fatal("the token is still there")
	}
}

// A clip downloaded before a stop, never handed over (the helper skips it
// as downloaded already), goes to its camera's pipeline at the next fetch,
// once; a download cut off is deleted; nothing stays in blink-incoming.
func TestALeftoverClipIsHandedOver(t *testing.T) {
	b, _, clips, _ := newBlink(t)
	os.WriteFile(b.TokenPath(), []byte("{}"), 0o600)
	b.camera("11", "Porch")
	in := filepath.Join(b.Dir, "blink-incoming", "11")
	os.MkdirAll(in, 0o700)
	os.WriteFile(filepath.Join(in, "rec-blink-20261014T120000.mp4"), []byte("video"), 0o600)
	os.WriteFile(filepath.Join(in, "rec-blink-20261014T115900.mp4.part"), []byte("vid"), 0o600)
	b.step(context.Background())
	if len(*clips) != 2 || (*clips)[0] != "blink_camera_2 rec-blink-20261014T120100.mp4" ||
		(*clips)[1] != "blink_camera_1 rec-blink-20261014T120000.mp4" {
		t.Fatalf("clips %v", *clips)
	}
	var left []string
	filepath.Walk(filepath.Join(b.Dir, "blink-incoming"), func(p string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			left = append(left, p)
		}
		return nil
	})
	if len(left) != 0 {
		t.Fatalf("left %v", left)
	}
}

// A camera removed in the app is no longer fetched nor registered, the
// status no longer lists it, and neither a fetch nor a new login makes it
// a device again; a disconnect forgets it, so a new connect brings it back
// as a new device.
func TestARemovedCameraStaysRemovedTillADisconnect(t *testing.T) {
	b, store, clips, registered := newBlink(t)
	ctx := context.Background()
	login(t, b, store, 1)
	b.step(ctx)
	// Porch (11) is blink_camera_1, Garden (22) blink_camera_2, Shed (33)
	// blink_camera_3.
	*clips = nil
	store.put(t, Request{Remove: "blink_camera_1", RequestedAt: 2})
	b.step(ctx)
	s := store.status(t)
	if s.State != StateConnected || s.RequestedAt != 2 || len(s.Cameras) != 2 ||
		s.Cameras[0].Name != "Garden" || s.Cameras[1].Name != "Shed" {
		t.Fatalf("status %+v", s)
	}
	if len(*registered) != 2 || (*registered)[0].DeviceID != "blink_camera_2" || (*registered)[1].DeviceID != "blink_camera_3" {
		t.Fatalf("registered %+v", *registered)
	}
	if _, ok := store.objects["devices/calm_quiet_otter/blink.json"]; ok {
		t.Fatal("the request is still in the cloud")
	}
	// Remembered across a restart.
	b.load()
	if c, ok := b.state.Removed["11"]; !ok || c.DeviceID != "blink_camera_1" {
		t.Fatalf("removed %+v", b.state.Removed)
	}

	// A fetch: the helper's told to skip it, and a clip of it isn't handed
	// over, nor left behind.
	b.lastFetch = time.Time{}
	b.step(ctx)
	if args, _ := os.ReadFile(filepath.Join(b.Dir, "fetch-args")); !strings.Contains(string(args), "--skip 11") {
		t.Fatalf("fetch args %q", args)
	}
	for _, c := range *clips {
		if strings.HasPrefix(c, "blink_camera_1 ") {
			t.Fatalf("the removed camera's clip was handed over: %v", *clips)
		}
	}
	if _, err := os.Stat(filepath.Join(b.Dir, "blink-incoming", "11", "rec-blink-20261014T120000.mp4")); err == nil {
		t.Fatal("the removed camera's clip was left behind")
	}
	if len(store.status(t).Cameras) != 2 {
		t.Fatalf("a fetch added it again: %+v", store.status(t).Cameras)
	}

	// Logging in again (Blink's login lists it) doesn't add it again.
	login(t, b, store, 3)
	b.step(ctx)
	if s := store.status(t); s.State != StateConnected || len(s.Cameras) != 2 || len(*registered) != 2 {
		t.Fatalf("a login added it again: %+v %+v", s, *registered)
	}

	// Disconnect, then connect: it's back, as a new device.
	store.put(t, Request{Disconnect: true, RequestedAt: 4})
	b.step(ctx)
	login(t, b, store, 5)
	b.step(ctx)
	s = store.status(t)
	if len(s.Cameras) != 3 || s.Cameras[1].Name != "Porch" || s.Cameras[1].DeviceID != "blink_camera_4" {
		t.Fatalf("not back as a new device: %+v", s.Cameras)
	}
	if len(*registered) != 3 {
		t.Fatalf("registered %+v", *registered)
	}
}

// Removing a camera that isn't one (any more) changes nothing, and is
// answered.
func TestRemovingAnUnknownCameraIsAnswered(t *testing.T) {
	b, store, _, registered := newBlink(t)
	b.camera("11", "Porch")
	store.put(t, Request{Remove: "zesty_owl", RequestedAt: 7})
	b.step(context.Background())
	s := store.status(t)
	if s.State != StateOff || s.RequestedAt != 7 || len(s.Cameras) != 1 || *registered != nil {
		t.Fatalf("status %+v, registered %+v", s, *registered)
	}
}
