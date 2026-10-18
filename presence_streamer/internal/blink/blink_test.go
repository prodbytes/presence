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
  out=$6
  mkdir -p "$out/11" "$out/33"
  echo video > "$out/11/rec-blink-20261014T120000.mp4"
  echo video > "$out/33/rec-blink-20261014T120100.mp4"
  echo '{"clip":{"camera":"11","name":"Porch","file":"'$out'/11/rec-blink-20261014T120000.mp4"}}'
  echo '{"clip":{"camera":"33","name":"Shed","file":"'$out'/33/rec-blink-20261014T120100.mp4"}}'
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
			return nil
		},
		Poll: 10 * time.Millisecond, Every: time.Hour, Backfill: 24 * time.Hour, PINWait: 5 * time.Second,
		Logf: t.Logf,
	}
	b.load()
	return b, store, &clips, &registered
}

func TestLoginWithAPINFromTheApp(t *testing.T) {
	b, store, clips, registered := newBlink(t)
	ctx := context.Background()
	store.put(t, Request{Email: "a@b.c", Password: "secret", RequestedAt: 1})
	// The app gives the PIN once the status asks for it, watching as long
	// as the streamer waits for it (the helper can be slow to ask on a
	// loaded machine).
	go func() {
		for deadline := time.Now().Add(b.PINWait + 5*time.Second); time.Now().Before(deadline); {
			time.Sleep(5 * time.Millisecond)
			store.mu.Lock()
			_, has := store.objects["devices/calm_quiet_otter/blink-status.json"]
			store.mu.Unlock()
			if has && store.status(t).State == StatePIN {
				store.put(t, Request{Email: "a@b.c", Password: "secret", PIN: "123456", RequestedAt: 1})
				return
			}
		}
	}()
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
