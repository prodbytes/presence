package usbcam

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

const streamer = "calm_quiet_otter"

var key = bytes.Repeat([]byte{7}, 32)

// The streamer's clock: 2026-10-14 13:00 UTC.
var epoch = time.Date(2026, 10, 14, 13, 0, 0, 0, time.UTC)

func at(day, hour, minute int) int64 {
	return time.Date(2026, 10, day, hour, minute, 0, 0, time.UTC).Unix()
}

// memStore is the profile's folder, in memory.
type memStore struct {
	mu      sync.Mutex
	objects map[string][]byte
	puts    int
}

func (m *memStore) Put(_ context.Context, path, key, _ string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.objects[key] = data
	m.puts++
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

// fakeGPhoto2 is gphoto2 as a shell script, on the files of its folder
// ($dir): autodetect (--auto-detect's output), summary, list (--list-files'),
// busy (there: the camera is claimed), cut (there: downloads are cut
// short), and data/<name> each file's content. Its calls go to calls.
const fakeGPhoto2 = `#!/bin/sh
dir=@DIR@
echo "$*" >> "$dir/calls"
case " $* " in
*" --auto-detect "*)
  echo 'Model                          Port            '
  echo '----------------------------------------------------------'
  cat "$dir/autodetect" 2>/dev/null
  exit 0;;
esac
[ -f "$dir/busy" ] && {
  echo '*** Error ***' >&2
  echo 'An error occurred in the io-library ('"'"'Could not claim the USB device'"'"'): Could not claim interface 0 (Device or resource busy).' >&2
  exit 1
}
case " $* " in
*" --summary "*) cat "$dir/summary";;
*" --list-files "*) cat "$dir/list";;
*" --get-file "*)
  while [ $# -gt 0 ]; do
    case "$1" in
    --get-file) src=$2; shift;;
    --filename) out=$2; shift;;
    esac
    shift
  done
  name=$(basename "$src")
  if [ -f "$dir/cut" ]; then head -c 100 "$dir/data/$name" > "$out"; else cat "$dir/data/$name" > "$out"; fi
  echo "Saving file as $out";;
esac
`

type harness struct {
	m          *Manager
	store      *memStore
	cam, sys   string
	clips      []string
	registered [][]Camera
	clock      time.Time
}

func newHarness(t *testing.T) *harness {
	h := &harness{store: &memStore{objects: map[string][]byte{}}, clock: epoch}
	root := t.TempDir()
	h.cam = filepath.Join(root, "camera")
	h.sys = filepath.Join(root, "sys")
	os.MkdirAll(filepath.Join(h.cam, "data"), 0o700)
	os.MkdirAll(h.sys, 0o700)
	os.WriteFile(filepath.Join(root, "gphoto2"), []byte(strings.Replace(fakeGPhoto2, "@DIR@", h.cam, 1)), 0o755)
	// A USB hub (class 9): not a camera.
	h.usb("1-1", 1, 2, "", "09")
	h.m = h.manager(t, filepath.Join(root, "state"))
	return h
}

func (h *harness) manager(t *testing.T, dir string) *Manager {
	os.MkdirAll(dir, 0o700)
	n := 0
	gphoto2 := filepath.Join(filepath.Dir(h.cam), "gphoto2")
	m := &Manager{
		Dir: dir, DeviceID: streamer, Key: key, Store: h.store, SysDir: h.sys,
		GPhoto2: func(ctx context.Context, args ...string) *exec.Cmd {
			return exec.CommandContext(ctx, gphoto2, args...)
		},
		NewDevice: func() string { n++; return fmt.Sprintf("usb_cam_%d", n) },
		Cameras: func(_ context.Context, cameras []Camera) error {
			h.registered = append(h.registered, cameras)
			return nil
		},
		Clip: func(_ context.Context, c Camera, f string) error {
			data, _ := os.ReadFile(f)
			h.clips = append(h.clips, fmt.Sprintf("%s %s %d", c.DeviceID, filepath.Base(f), len(data)))
			return os.Remove(f)
		},
		Poll: time.Millisecond, Every: 2 * time.Minute, Backfill: 24 * time.Hour,
		MaxBytes: 1 << 20,
		Now:      func() time.Time { return h.clock },
		Logf:     t.Logf,
	}
	m.Known()
	return m
}

// usb puts a USB device in the kernel's list, with an interface of class.
func (h *harness) usb(name string, bus, dev int, serial, class string) {
	d := filepath.Join(h.sys, name)
	os.MkdirAll(filepath.Join(d, name+":1.0"), 0o700)
	os.WriteFile(filepath.Join(d, "busnum"), []byte(fmt.Sprintln(bus)), 0o600)
	os.WriteFile(filepath.Join(d, "devnum"), []byte(fmt.Sprintln(dev)), 0o600)
	if serial != "" {
		os.WriteFile(filepath.Join(d, "serial"), []byte(serial+"\n"), 0o600)
	}
	os.WriteFile(filepath.Join(d, name+":1.0", "bInterfaceClass"), []byte(class+"\n"), 0o600)
}

// plug plugs the GoPro in at usb:001,dev.
func (h *harness) plug(dev int) {
	h.usb("1-1.2", 1, dev, "C3221324700631", "06")
	h.write("autodetect", fmt.Sprintf("GoPro HERO6 Black              usb:001,%03d     \n", dev))
}

func (h *harness) unplug() {
	os.RemoveAll(filepath.Join(h.sys, "1-1.2"))
	os.Remove(filepath.Join(h.cam, "autodetect"))
}

func (h *harness) write(name, content string) {
	os.WriteFile(filepath.Join(h.cam, name), []byte(content), 0o600)
}

func (h *harness) calls() string {
	data, _ := os.ReadFile(filepath.Join(h.cam, "calls"))
	return string(data)
}

// files puts files on the camera: name and time (data/<name> holds 2 KB).
func (h *harness) files(files ...File) {
	var b strings.Builder
	b.WriteString("There is no file in folder '/'.\nThere is no file in folder '/store_00010001'.\n")
	fmt.Fprintf(&b, "There are %d files in folder '/store_00010001/DCIM/100GOPRO'.\n", len(files))
	for i, f := range files {
		kb := f.KB
		if kb == 0 {
			kb = 2
		}
		fmt.Fprintf(&b, "#%-5d %-27srd %5d KB video/mp4 %d\n", i+1, f.Name, kb, f.Time)
		os.WriteFile(filepath.Join(h.cam, "data", f.Name), bytes.Repeat([]byte(f.Name[:1]), 2048), 0o600)
	}
	h.write("list", b.String())
}

func (h *harness) request(t *testing.T, req Request) {
	var sealed bytes.Buffer
	data, _ := json.Marshal(req)
	if err := seal.Seal(&sealed, bytes.NewReader(data), key, streamer, nil); err != nil {
		t.Fatal(err)
	}
	h.store.mu.Lock()
	h.store.objects["devices/"+streamer+"/usbcam.json"] = sealed.Bytes()
	h.store.mu.Unlock()
	h.m.Step(context.Background())
}

func (h *harness) step() { h.m.Step(context.Background()) }

func (h *harness) tick() {
	h.clock = h.clock.Add(h.m.Every)
	h.step()
}

func (h *harness) status(t *testing.T) Status {
	h.store.mu.Lock()
	sealed := h.store.objects["devices/"+streamer+"/usbcam-status.json"]
	h.store.mu.Unlock()
	var plain bytes.Buffer
	if err := seal.Open(&plain, bytes.NewReader(sealed), key); err != nil {
		t.Fatal(err)
	}
	var s Status
	json.Unmarshal(plain.Bytes(), &s)
	return s
}

func TestNothingPluggedIn(t *testing.T) {
	h := newHarness(t)
	h.step()
	h.step()
	if s := h.status(t); s.State != StateOff || len(s.Detected) != 0 {
		t.Fatalf("status = %+v", s)
	}
	// No still-image device: gphoto2 isn't run, and the status put once.
	if c := h.calls(); c != "" {
		t.Fatalf("gphoto2 ran: %q", c)
	}
	if h.store.puts != 1 {
		t.Fatalf("%d puts", h.store.puts)
	}
}

func TestDetectAddFetchRemove(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(
		File{Name: "GOPR0001.MP4", Time: at(12, 12, 0)}, // before the backfill
		File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)},
		File{Name: "GOPR0002.LRV", Time: at(14, 10, 0)},
		File{Name: "GOPR0002.THM", Time: at(14, 10, 0)},
		File{Name: "GOPR0003.JPG", Time: at(14, 11, 0)},
		File{Name: "GP010002.MOV", Time: at(14, 10, 30)},
		File{Name: "GOPR0004.MP4", Time: at(14, 12, 0), KB: 4096}, // too big
	)
	h.step()
	s := h.status(t)
	if s.State != StateOK || len(s.Detected) != 1 || s.Detected[0] != (Detected{Model: "GoPro HERO6 Black", Serial: "C3221324700631", Port: "usb:001,004"}) {
		t.Fatalf("status = %+v", s)
	}
	// Detected again only when the kernel's list changes.
	h.step()
	if n := strings.Count(h.calls(), "--auto-detect"); n != 1 {
		t.Fatalf("auto-detect ran %d times", n)
	}

	h.request(t, Request{Add: &Add{Name: "Helmet", Serial: "C3221324700631"}, RequestedAt: 1})
	if len(h.registered) != 1 || h.registered[0][0].DeviceID != "usb_cam_1" {
		t.Fatalf("registered = %+v", h.registered)
	}
	if _, ok := h.store.objects["devices/"+streamer+"/usbcam.json"]; ok {
		t.Fatal("the request stayed")
	}
	want := []string{
		"usb_cam_1 rec-usbcam-20261014T100000.mp4 2048",
		"usb_cam_1 rec-usbcam-20261014T103000.mp4 2048",
	}
	if fmt.Sprint(h.clips) != fmt.Sprint(want) {
		t.Fatalf("clips = %q", h.clips)
	}
	if !strings.Contains(h.calls(), "--get-file /store_00010001/DCIM/100GOPRO/GOPR0002.MP4") {
		t.Fatalf("calls = %s", h.calls())
	}
	s = h.status(t)
	if s.RequestedAt != 1 || len(s.Cameras) != 1 {
		t.Fatalf("status = %+v", s)
	}
	if c := s.Cameras[0]; c.Name != "Helmet" || c.Model != "GoPro HERO6 Black" || !c.Plugged || c.LastFetch != epoch.UnixMilli() || c.Error != "" {
		t.Fatalf("camera = %+v", c)
	}

	// Nothing twice, also after a restart; a new video is fetched.
	h.tick()
	h.m = h.manager(t, h.m.Dir)
	h.tick()
	if len(h.clips) != 2 {
		t.Fatalf("clips = %q", h.clips)
	}
	h.files(
		File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)},
		File{Name: "GOPR0005.MP4", Time: at(14, 13, 0)},
	)
	h.tick()
	if len(h.clips) != 3 || !strings.Contains(h.clips[2], "rec-usbcam-20261014T130000.mp4") {
		t.Fatalf("clips = %q", h.clips)
	}
	// Those gone from the camera are forgotten.
	if c := h.m.state.Cameras["usb_cam_1"]; len(c.Fetched) != 2 {
		t.Fatalf("fetched = %v", c.Fetched)
	}
	if left, _ := os.ReadDir(filepath.Join(h.m.Dir, "usbcam-incoming", "usb_cam_1")); len(left) != 0 {
		t.Fatalf("left in incoming: %v", left)
	}

	h.request(t, Request{Remove: "usb_cam_1", RequestedAt: 2})
	if s := h.status(t); len(s.Cameras) != 0 || len(s.Detected) != 1 || s.RequestedAt != 2 {
		t.Fatalf("status = %+v", s)
	}
	if last := h.registered[len(h.registered)-1]; len(last) != 0 {
		t.Fatalf("registered = %+v", last)
	}
	// The same request isn't handled twice.
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 2})
	if len(h.m.state.Cameras) != 0 {
		t.Fatal("handled twice")
	}
}

func TestUnpluggedAndReplugged(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)})
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 1})
	if len(h.clips) != 1 || h.status(t).Cameras[0].Name != "GoPro HERO6 Black" {
		t.Fatalf("clips = %q, status = %+v", h.clips, h.status(t))
	}
	h.unplug()
	h.step()
	s := h.status(t)
	if len(s.Detected) != 0 || s.Cameras[0].Plugged || s.Cameras[0].Error != "" {
		t.Fatalf("status = %+v", s)
	}
	listed := strings.Count(h.calls(), "--list-files")
	h.tick()
	if strings.Count(h.calls(), "--list-files") != listed {
		t.Fatal("listed while unplugged")
	}
	// Back on another port, with a new video: fetched at once, by serial.
	h.files(
		File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)},
		File{Name: "GOPR0003.MP4", Time: at(14, 12, 0)},
	)
	h.plug(7)
	h.step()
	if len(h.clips) != 2 || !strings.Contains(h.calls(), "--port usb:001,007 --get-file /store_00010001/DCIM/100GOPRO/GOPR0003.MP4") {
		t.Fatalf("clips = %q, calls = %s", h.clips, h.calls())
	}
	if c := h.status(t).Cameras[0]; !c.Plugged || c.DeviceID != "usb_cam_1" {
		t.Fatalf("camera = %+v", c)
	}
}

func TestBusyAndCutOff(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)})
	h.write("busy", "")
	h.request(t, Request{Add: &Add{Name: "Helmet", Serial: "C3221324700631"}, RequestedAt: 1})
	if c := h.status(t).Cameras[0]; c.Error != ErrBusy.Error() || !c.Plugged {
		t.Fatalf("camera = %+v", c)
	}
	os.Remove(filepath.Join(h.cam, "busy"))
	h.write("cut", "")
	h.tick()
	if c := h.status(t).Cameras[0]; !strings.Contains(c.Error, "cut off") || len(h.clips) != 0 {
		t.Fatalf("camera = %+v, clips = %q", c, h.clips)
	}
	if left, _ := os.ReadDir(filepath.Join(h.m.Dir, "usbcam-incoming", "usb_cam_1")); len(left) != 0 {
		t.Fatalf("left in incoming: %v", left)
	}
	// Tried again.
	os.Remove(filepath.Join(h.cam, "cut"))
	h.tick()
	if c := h.status(t).Cameras[0]; c.Error != "" || len(h.clips) != 1 {
		t.Fatalf("camera = %+v, clips = %q", c, h.clips)
	}
}

func TestSerialFromSummaryAndMissingGPhoto2(t *testing.T) {
	h := newHarness(t)
	h.usb("1-1.3", 1, 5, "", "06")
	h.write("autodetect", "Canon EOS 600D                 usb:001,005\n")
	h.write("summary", "Camera summary:\nManufacturer: Canon Inc.\nModel: Canon EOS 600D\n  Version: 3-1.0.2\n  Serial Number: 0123abc\n")
	h.step()
	if d := h.status(t).Detected; len(d) != 1 || d[0].Serial != "0123abc" || d[0].Model != "Canon EOS 600D" {
		t.Fatalf("detected = %+v", d)
	}

	h2 := newHarness(t)
	h2.m.GPhoto2 = func(ctx context.Context, args ...string) *exec.Cmd {
		return exec.CommandContext(ctx, filepath.Join(t.TempDir(), "no-gphoto2"), args...)
	}
	h2.plug(4)
	h2.step()
	if s := h2.status(t); s.State != StateError || s.Error != ErrNoGPhoto2.Error() {
		t.Fatalf("status = %+v", s)
	}
}

func TestParseFiles(t *testing.T) {
	out := `There is no file in folder '/'.
There is 1 file in folder '/store_00010001/DCIM/100GOPRO'.
#1     GOPR0002.MP4               rd 123456 KB video/mp4 1760443200
There are 2 files in folder '/store_00010001/DCIM/101GOPRO'.
#1     IMG_0001.JPG               rd  3922 KB 4000x3000 image/jpeg 1760443300
#2     NOINFO.MOV
`
	got := ParseFiles(out)
	want := []File{
		{Folder: "/store_00010001/DCIM/100GOPRO", Name: "GOPR0002.MP4", KB: 123456, Time: 1760443200},
		{Folder: "/store_00010001/DCIM/101GOPRO", Name: "IMG_0001.JPG", KB: 3922, Time: 1760443300},
		{Folder: "/store_00010001/DCIM/101GOPRO", Name: "NOINFO.MOV"},
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %+v", got)
	}
	if !got[0].IsVideo() || got[1].IsVideo() || !got[2].IsVideo() || (File{Name: "GL010002.LRV"}).IsVideo() {
		t.Fatal("IsVideo")
	}
}
