package usbcam

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path"
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
// ($dir): autodetect (--auto-detect's output), summary, list (--list-files';
// list.next replaces it once listed: a file growing), busy (there: the
// camera is claimed), cut (there: downloads are cut short), nodelete
// (there: deleting fails), and data/<name> each file's content. Its calls
// go to calls; --delete-file takes the file off list.
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
*" --list-files "*)
  cat "$dir/list"
  [ -f "$dir/list.next" ] && mv "$dir/list.next" "$dir/list"
  exit 0;;
*" --delete-file "*)
  [ -f "$dir/nodelete" ] && { echo '*** Error ***' >&2; echo 'An error occurred in the io-library: PTP Access Denied' >&2; exit 1; }
  while [ $# -gt 0 ]; do
    [ "$1" = --delete-file ] && src=$2
    shift
  done
  name=$(basename "$src")
  grep -v "[[:space:]]$name[[:space:]]" "$dir/list" > "$dir/list.tmp"
  mv "$dir/list.tmp" "$dir/list"
  rm -f "$dir/data/$name";;
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
	// free is the disk's room; spooled what the camera's spool holds.
	free, spooled int64
}

func newHarness(t *testing.T) *harness {
	h := &harness{store: &memStore{objects: map[string][]byte{}}, clock: epoch, free: 1 << 40}
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
		Spooled:  func(Camera) int64 { return h.spooled },
		MaxSpool: 4000,
		Free:     func() (int64, error) { return h.free, nil },
		MinFree:  1 << 20,
		Settle:   time.Millisecond,
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

func (h *harness) read(name string) string {
	data, _ := os.ReadFile(filepath.Join(h.cam, name))
	return string(data)
}

func (h *harness) calls() string {
	data, _ := os.ReadFile(filepath.Join(h.cam, "calls"))
	return string(data)
}

// files puts files on the camera: name, time and size (2 KB unless said;
// data/<name> holds it).
func (h *harness) files(files ...File) {
	for _, f := range files {
		kb := f.KB
		if kb == 0 {
			kb = 2
		}
		os.WriteFile(filepath.Join(h.cam, "data", f.Name), bytes.Repeat([]byte(f.Name[:1]), int(kb)<<10), 0o600)
	}
	h.write("list", listing(files...))
}

// listing is --list-files' output for files.
func listing(files ...File) string {
	var b strings.Builder
	b.WriteString("There is no file in folder '/'.\nThere is no file in folder '/store_00010001'.\n")
	fmt.Fprintf(&b, "There are %d files in folder '/store_00010001/DCIM/100GOPRO'.\n", len(files))
	for i, f := range files {
		kb := f.KB
		if kb == 0 {
			kb = 2
		}
		fmt.Fprintf(&b, "#%-5d %-27srd %5d KB video/mp4 %d\n", i+1, f.Name, kb, f.Time)
	}
	return b.String()
}

var attended = new(bool)

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

	h.request(t, Request{Add: &Add{Name: "Helmet", Serial: "C3221324700631", Unattended: attended}, RequestedAt: 1})
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
	if c := s.Cameras[0]; c.Name != "Helmet" || c.Model != "GoPro HERO6 Black" || !c.Plugged || c.LastFetch != epoch.UnixMilli() || c.Error != "" || c.Unattended {
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
	// Attended: nothing on the camera is deleted.
	if strings.Contains(h.calls(), "--delete-file") {
		t.Fatalf("calls = %s", h.calls())
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

func (h *harness) deleted() []string {
	var out []string
	for _, line := range strings.Split(h.calls(), "\n") {
		if _, file, ok := strings.Cut(line, "--delete-file "); ok {
			out = append(out, path.Base(file))
		}
	}
	return out
}

// Unattended (the default): each video downloaded whole is deleted from the
// camera, its own .LRV and .THM first; nothing else is.
func TestUnattendedDeletesFetchedVideos(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(
		File{Name: "GOPR0001.MP4", Time: at(12, 12, 0)}, // before the backfill
		File{Name: "GOPR0001.LRV", Time: at(12, 12, 0)},
		File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)},
		File{Name: "GOPR0002.LRV", Time: at(14, 10, 0)},
		File{Name: "GOPR0002.THM", Time: at(14, 10, 0)},
		File{Name: "GOPR0003.JPG", Time: at(14, 11, 0)},
		File{Name: "GH010004.MP4", Time: at(14, 12, 0)},
		File{Name: "GL010004.LRV", Time: at(14, 12, 0)},
		File{Name: "GH010004.THM", Time: at(14, 12, 0)},
	)
	h.request(t, Request{Add: &Add{Name: "Porch", Serial: "C3221324700631"}, RequestedAt: 1})
	if len(h.clips) != 2 {
		t.Fatalf("clips = %q", h.clips)
	}
	want := []string{"GOPR0002.LRV", "GOPR0002.THM", "GOPR0002.MP4", "GL010004.LRV", "GH010004.THM", "GH010004.MP4"}
	if fmt.Sprint(h.deleted()) != fmt.Sprint(want) {
		t.Fatalf("deleted %q", h.deleted())
	}
	// Each one deleted only after its download.
	calls := h.calls()
	if strings.Index(calls, "--get-file /store_00010001/DCIM/100GOPRO/GH010004.MP4") > strings.Index(calls, "--delete-file /store_00010001/DCIM/100GOPRO/GH010004.MP4") {
		t.Fatalf("calls = %s", calls)
	}
	left := ParseFiles(h.read("list"))
	if len(left) != 3 {
		t.Fatalf("left on the camera: %+v", left)
	}
	s := h.status(t)
	if c := s.Cameras[0]; !c.Unattended || c.Error != "" {
		t.Fatalf("camera = %+v", c)
	}
	if c := h.registered[0][0]; !c.IsUnattended() {
		t.Fatalf("registered = %+v", c)
	}
	// Nothing fetched or deleted twice.
	h.tick()
	if len(h.clips) != 2 || len(h.deleted()) != 6 {
		t.Fatalf("clips = %q, deleted %q", h.clips, h.deleted())
	}
}

// A delete that fails is said, and tried again at the next fetch; the
// video isn't fetched again.
func TestDeleteFailsThenRetried(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)}, File{Name: "GOPR0002.LRV", Time: at(14, 10, 0)})
	h.write("nodelete", "")
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 1})
	if c := h.status(t).Cameras[0]; !strings.Contains(c.Error, "couldn't delete /store_00010001/DCIM/100GOPRO/GOPR0002.LRV from the camera") || len(h.clips) != 1 {
		t.Fatalf("camera = %+v, clips = %q", c, h.clips)
	}
	// After a restart too.
	h.m = h.manager(t, h.m.Dir)
	os.Remove(filepath.Join(h.cam, "nodelete"))
	h.tick()
	if c := h.status(t).Cameras[0]; c.Error != "" || len(h.clips) != 1 {
		t.Fatalf("camera = %+v, clips = %q", c, h.clips)
	}
	if left := ParseFiles(h.read("list")); len(left) != 0 {
		t.Fatalf("left on the camera: %+v", left)
	}
	if c := h.m.state.Cameras["usb_cam_1"]; len(c.Got) != 0 {
		t.Fatalf("got = %v", c.Got)
	}
}

// A download cut off is never deleted from the camera.
func TestCutOffNotDeleted(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)})
	h.write("cut", "")
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 1})
	if len(h.deleted()) != 0 || len(h.clips) != 0 {
		t.Fatalf("deleted %q, clips %q", h.deleted(), h.clips)
	}
}

// A video still being written (its size changes between two listings)
// isn't fetched, nor deleted, till its size holds.
func TestGrowingVideoWaits(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)}, File{Name: "GOPR0003.MP4", Time: at(14, 12, 0), KB: 2})
	h.write("list.next", listing(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)}, File{Name: "GOPR0003.MP4", Time: at(14, 12, 0), KB: 3}))
	os.WriteFile(filepath.Join(h.cam, "data", "GOPR0003.MP4"), bytes.Repeat([]byte("G"), 3<<10), 0o600)
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 1})
	if len(h.clips) != 1 || strings.Contains(h.calls(), "--get-file /store_00010001/DCIM/100GOPRO/GOPR0003") {
		t.Fatalf("clips = %q, calls = %s", h.clips, h.calls())
	}
	if fmt.Sprint(h.deleted()) != "[GOPR0002.MP4]" {
		t.Fatalf("deleted %q", h.deleted())
	}
	// Done: the same size as the last listing.
	h.tick()
	if len(h.clips) != 2 || !strings.HasSuffix(h.clips[1], " 3072") || fmt.Sprint(h.deleted()) != "[GOPR0002.MP4 GOPR0003.MP4]" {
		t.Fatalf("clips = %q, deleted %q", h.clips, h.deleted())
	}
}

// A big video (a GoPro's 4 GB chapter) is fetched once the disk has room
// for it and its chunks; meanwhile the camera says it's waiting.
func TestBigVideoWaitsForRoom(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0), KB: 4096})
	h.free = 8 << 20 // 2 × 4 MB + 1 MB needed
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 1})
	if c := h.status(t).Cameras[0]; !strings.Contains(c.Error, "waiting for room on the streamer: GOPR0002.MP4 needs 9 MB, 8 MB free") ||
		strings.Contains(h.calls(), "--get-file") || len(h.deleted()) != 0 {
		t.Fatalf("camera = %+v, calls = %s", c, h.calls())
	}
	h.free = 9 << 20
	h.tick()
	if c := h.status(t).Cameras[0]; c.Error != "" || len(h.clips) != 1 || !strings.HasSuffix(h.clips[0], fmt.Sprint(4096<<10)) {
		t.Fatalf("camera = %+v, clips = %q", c, h.clips)
	}
}

// The app turns unattended off and on: said in the status and given to
// the pipelines; off, nothing on the camera is deleted.
func TestSetUnattended(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)})
	h.request(t, Request{Add: &Add{Serial: "C3221324700631", Unattended: attended}, RequestedAt: 1})
	if c := h.status(t).Cameras[0]; c.Unattended || len(h.deleted()) != 0 || len(h.clips) != 1 {
		t.Fatalf("camera = %+v, deleted %q", c, h.deleted())
	}
	h.request(t, Request{Set: &Set{DeviceID: "usb_cam_1", Unattended: true}, RequestedAt: 2})
	if c := h.status(t).Cameras[0]; !c.Unattended || h.status(t).RequestedAt != 2 {
		t.Fatalf("camera = %+v", c)
	}
	if last := h.registered[len(h.registered)-1]; !last[0].IsUnattended() {
		t.Fatalf("registered = %+v", last)
	}
	// On: the video downloaded whole before is deleted now.
	h.tick()
	if fmt.Sprint(h.deleted()) != "[GOPR0002.MP4]" || len(h.clips) != 1 {
		t.Fatalf("deleted %q, clips %q", h.deleted(), h.clips)
	}
	h.request(t, Request{Set: &Set{DeviceID: "usb_cam_1", Unattended: false}, RequestedAt: 3})
	if c := h.status(t).Cameras[0]; c.Unattended {
		t.Fatalf("camera = %+v", c)
	}
	// Added again: as it was, unless said.
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 4})
	if c := h.status(t).Cameras[0]; c.Unattended {
		t.Fatalf("camera = %+v", c)
	}
}

// Each video is split into chunks named by their start; they're handed
// over while the camera's spool holds less than half of MaxSpool, and the
// whole video is deleted once split.
func TestSplitAndHandOver(t *testing.T) {
	h := newHarness(t)
	var splits []string
	h.m.Split = func(_ context.Context, video, dir string, start time.Time) error {
		splits = append(splits, filepath.Base(video))
		for i := range 3 {
			os.WriteFile(filepath.Join(dir, ChunkName(start.Add(time.Duration(i)*30*time.Second))), bytes.Repeat([]byte("c"), 1000), 0o600)
		}
		return nil
	}
	h.plug(4)
	h.files(File{Name: "GOPR0002.MP4", Time: at(14, 10, 0)})
	h.spooled = 1500
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 1})
	incoming := filepath.Join(h.m.Dir, "usbcam-incoming", "usb_cam_1")
	if fmt.Sprint(splits) != "[video-20261014T100000.mp4]" || len(h.clips) != 0 {
		t.Fatalf("splits %q, clips %q", splits, h.clips)
	}
	if left, _ := filepath.Glob(filepath.Join(incoming, "*")); fmt.Sprint(left) != fmt.Sprint([]string{filepath.Join(incoming, "chunks-20261014T100000")}) {
		t.Fatalf("incoming: %v", left)
	}
	// Room: two fit in half the spool, the third waits.
	h.spooled = 0
	h.step()
	want := []string{
		"usb_cam_1 rec-usbcam-20261014T100000.mp4 1000",
		"usb_cam_1 rec-usbcam-20261014T100030.mp4 1000",
	}
	if fmt.Sprint(h.clips) != fmt.Sprint(want) {
		t.Fatalf("clips %q", h.clips)
	}
	h.step()
	if len(h.clips) != 3 || !strings.Contains(h.clips[2], "rec-usbcam-20261014T100100.mp4") {
		t.Fatalf("clips %q", h.clips)
	}
	if left, _ := os.ReadDir(incoming); len(left) != 0 {
		t.Fatalf("left in incoming: %v", left)
	}
}

// What a stop left in incoming carries on: a split cut off is done again;
// a video split already, but not deleted, is deleted, and its chunks
// handed over.
func TestIncomingAfterAStop(t *testing.T) {
	h := newHarness(t)
	h.plug(4)
	h.files()
	h.request(t, Request{Add: &Add{Serial: "C3221324700631"}, RequestedAt: 1})
	incoming := filepath.Join(h.m.Dir, "usbcam-incoming", "usb_cam_1")
	os.MkdirAll(filepath.Join(incoming, "split-20261014T100000"), 0o700)
	os.WriteFile(filepath.Join(incoming, "split-20261014T100000", "part-00000.mp4"), []byte("half"), 0o600)
	os.WriteFile(filepath.Join(incoming, "video-20261014T100000.mp4"), []byte("whole"), 0o600)
	os.MkdirAll(filepath.Join(incoming, "chunks-20261014T110000"), 0o700)
	os.WriteFile(filepath.Join(incoming, "chunks-20261014T110000", ChunkName(time.Unix(at(14, 11, 0), 0))), []byte("chunk"), 0o600)
	os.WriteFile(filepath.Join(incoming, "video-20261014T110000.mp4"), []byte("whole"), 0o600)
	os.WriteFile(filepath.Join(incoming, "video-20261014T120000.mp4.part"), []byte("cut"), 0o600)
	h.step()
	want := []string{
		"usb_cam_1 rec-usbcam-20261014T100000.mp4 5",
		"usb_cam_1 rec-usbcam-20261014T110000.mp4 5",
	}
	if fmt.Sprint(h.clips) != fmt.Sprint(want) {
		t.Fatalf("clips %q", h.clips)
	}
	if left, _ := os.ReadDir(incoming); len(left) != 0 {
		t.Fatalf("left in incoming: %v", left)
	}
}

func TestSidecars(t *testing.T) {
	dir := "/store_00010001/DCIM/100GOPRO"
	files := []File{
		{Folder: dir, Name: "GOPR0002.MP4"}, {Folder: dir, Name: "GOPR0002.LRV"}, {Folder: dir, Name: "GOPR0002.THM"},
		{Folder: dir, Name: "GP010002.MP4"}, {Folder: dir, Name: "GP010002.LRV"},
		{Folder: dir, Name: "GX010003.MP4"}, {Folder: dir, Name: "GL010003.LRV"}, {Folder: dir, Name: "GX010003.THM"},
		{Folder: dir, Name: "GOPR0002.JPG"}, {Folder: "/store_00010001/DCIM/101GOPRO", Name: "GOPR0002.LRV"},
	}
	for video, want := range map[string]string{
		"GOPR0002.MP4": "[GOPR0002.LRV GOPR0002.THM]",
		"GP010002.MP4": "[GP010002.LRV]",
		"GX010003.MP4": "[GL010003.LRV GX010003.THM]",
	} {
		var got []string
		for _, f := range Sidecars(File{Folder: dir, Name: video}, files) {
			got = append(got, f.Name)
		}
		if fmt.Sprint(got) != want {
			t.Errorf("%s: %q", video, got)
		}
	}
}

// A video (with a data stream, as a GoPro's telemetry) is split by ffmpeg,
// copied, into chunks named by their start, each playable.
func TestSplitVideo(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	ffprobe, _ := exec.LookPath("ffprobe")
	dir := t.TempDir()
	video := filepath.Join(dir, "video.mp4")
	// 7 s at 10 fps, a keyframe a second, with sound and a timecode track
	// (a data stream).
	if out, err := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=10:duration=7",
		"-f", "lavfi", "-i", "sine=duration=7", "-c:v", "libx264", "-g", "10", "-c:a", "aac", "-timecode", "10:00:00:00", "-shortest", video).CombinedOutput(); err != nil {
		t.Skipf("can't make a video: %v %s", err, out)
	}
	out := filepath.Join(dir, "chunks")
	os.MkdirAll(out, 0o700)
	start := time.Date(2026, 10, 14, 10, 0, 0, 0, time.UTC)
	if err := SplitVideo(context.Background(), ffmpeg, video, out, start, 2*time.Second); err != nil {
		t.Fatal(err)
	}
	names, _ := filepath.Glob(filepath.Join(out, "*"))
	var got []string
	for _, n := range names {
		got = append(got, filepath.Base(n))
	}
	want := []string{"rec-usbcam-20261014T100000.mp4", "rec-usbcam-20261014T100002.mp4", "rec-usbcam-20261014T100004.mp4", "rec-usbcam-20261014T100006.mp4"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("chunks %q", got)
	}
	for _, n := range names {
		if out, err := exec.Command(ffprobe, "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", n).Output(); err != nil || !strings.Contains(string(out), "video") || !strings.Contains(string(out), "audio") || strings.Contains(string(out), "data") {
			t.Errorf("%s: %v %s", n, err, out)
		}
	}
	// Not a video: an error.
	os.WriteFile(video, []byte("not a video"), 0o600)
	if err := SplitVideo(context.Background(), ffmpeg, video, t.TempDir(), start, 2*time.Second); err == nil {
		t.Fatal("split a broken video")
	}
}
