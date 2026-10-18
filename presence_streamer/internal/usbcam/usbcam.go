// Package usbcam makes cameras plugged into the streamer by USB Presence
// devices (specs/usb-cameras.md): still-image cameras (USB interface class
// 6, PTP or MTP: a GoPro HERO5 to HERO8, most digital cameras), reached
// with libgphoto2's `gphoto2` command, no network and no address. One
// streamer of the profile, the one the app's Settings pick, detects the
// cameras plugged into it, and fetches the videos each one added recorded.
// Every camera added becomes a device of its own, with an ID made here,
// whose videos go through the same chunk pipeline as the Pi's own
// recordings. A camera is known by its USB serial number, the same on any
// port and after a replug.
//
// The app and this streamer talk through the profile's folder, sealed with
// this streamer's media key (only the profile's devices hold it):
//
//   - devices/<streamer>/usbcam.json, the app's request: {"add": {"name",
//     "serial"}} or {"remove": "<device ID>"}, and "requestedAt". Deleted
//     once handled.
//   - devices/<streamer>/usbcam-status.json, this streamer's answer:
//     {"state", "error", "detected": [{"model", "serial", "port"}],
//     "cameras": [{"name", "model", "serial", "deviceId", "plugged",
//     "lastFetch", "error"}], "requestedAt", "updatedAt"}.
//
// Here, in the state folder: usbcam-state.json (mode 600: the cameras,
// and the videos fetched from each).
package usbcam

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// Name names its files, spool and logs.
const Name = "usbcam"

// States the status says.
const (
	StateOff   = "off"
	StateOK    = "ok"
	StateError = "error"
)

// ErrBusy is a camera another program holds (the desktop's file manager,
// gvfs, mounts cameras as they're plugged in).
var ErrBusy = errors.New("the camera is busy: another program (the desktop's file manager) has it open")

// ErrNoGPhoto2 is the gphoto2 command missing.
var ErrNoGPhoto2 = errors.New("gphoto2 isn't installed (sudo apt install gphoto2)")

// Store is the profile's folder in the bucket.
type Store interface {
	Put(ctx context.Context, path, key, contentType string) error
	Get(ctx context.Context, key, path string) error
	Delete(ctx context.Context, key string) error
}

// Add is a camera the app adds: one the status listed as detected.
type Add struct {
	Name   string `json:"name"`
	Serial string `json:"serial"`
}

// Request is the app's (devices/<streamer>/usbcam.json).
type Request struct {
	Add         *Add   `json:"add,omitempty"`
	Remove      string `json:"remove,omitempty"`
	RequestedAt int64  `json:"requestedAt"`
}

// Detected is a camera plugged in.
type Detected struct {
	// Model is gphoto2's name for it ("GoPro HERO6 Black").
	Model  string `json:"model"`
	Serial string `json:"serial"`
	// Port is gphoto2's ("usb:001,004"): it changes with a replug.
	Port string `json:"port"`
}

// Camera is a camera added and the Presence device it is.
type Camera struct {
	Name     string `json:"name"`
	Model    string `json:"model,omitempty"`
	Serial   string `json:"serial"`
	DeviceID string `json:"deviceId"`
	// Since is how far back videos are fetched (epoch seconds): a day
	// before the camera was added.
	Since int64 `json:"since,omitempty"`
	// Listed is whether its files were ever listed: a video without a
	// time on the first listing is taken as old.
	Listed bool `json:"listed,omitempty"`
	// Fetched are the videos fetched (or skipped), by their path on the
	// camera: their size in KB and time, "<KB>:<time>", so a file written
	// over under the same name is fetched again.
	Fetched map[string]string `json:"fetched,omitempty"`
}

// Status is this streamer's answer (devices/<streamer>/usbcam-status.json).
type Status struct {
	State       string         `json:"state"`
	Error       string         `json:"error,omitempty"`
	Detected    []Detected     `json:"detected,omitempty"`
	Cameras     []StatusCamera `json:"cameras,omitempty"`
	RequestedAt int64          `json:"requestedAt,omitempty"`
	UpdatedAt   int64          `json:"updatedAt"`
}

// StatusCamera is a camera added, as the app lists it.
type StatusCamera struct {
	Name      string `json:"name"`
	Model     string `json:"model,omitempty"`
	Serial    string `json:"serial"`
	DeviceID  string `json:"deviceId"`
	Plugged   bool   `json:"plugged"`
	LastFetch int64  `json:"lastFetch,omitempty"`
	Error     string `json:"error,omitempty"`
}

// saved is usbcam-state.json.
type saved struct {
	Cameras map[string]Camera `json:"cameras,omitempty"`
	// Handled is the requestedAt of the last request handled.
	Handled int64 `json:"handled,omitempty"`
}

// Manager detects the cameras plugged in and fetches the added ones'
// videos for their devices.
type Manager struct {
	// Dir is the state folder.
	Dir string
	// DeviceID is this streamer's; Key its media key.
	DeviceID string
	Key      []byte
	Store    Store
	// GPhoto2 is the gphoto2 command with args.
	GPhoto2 func(ctx context.Context, args ...string) *exec.Cmd
	// SysDir is where the kernel lists USB devices (/sys/bus/usb/devices):
	// gphoto2 runs only when a still-image device is there, and the
	// serial numbers come from it.
	SysDir string
	// NewDevice makes a camera's device ID.
	NewDevice func() string
	// Cameras is told the cameras whenever they change, so they join the
	// profile's devices and get their pipelines (removed ones stop).
	Cameras func(ctx context.Context, cameras []Camera) error
	// Clip hands a camera's fetched video to its pipeline (it's moved).
	Clip func(ctx context.Context, camera Camera, file string) error
	// Poll is how often the request and the cameras plugged in are looked
	// for; Every how often videos are fetched; Backfill how far back a new
	// camera's first fetch goes.
	Poll, Every, Backfill time.Duration
	// MaxBytes is the biggest video fetched (0: any); bigger ones are
	// skipped.
	MaxBytes int64
	Now      func() time.Time
	Logf     func(string, ...any)

	state     saved
	loaded    bool
	lastFetch time.Time
	fetched   map[string]int64
	errs      map[string]string
	// detected are the cameras plugged in; usb what the kernel listed when
	// they were detected (detection runs again when it changes); detectErr
	// why they couldn't be.
	detected  []Detected
	usb       string
	detectErr string
	// published is the last status put; dirty a change since.
	published bool
	dirty     bool
}

func (m *Manager) statePath() string  { return filepath.Join(m.Dir, Name+"-state.json") }
func (m *Manager) requestKey() string { return "devices/" + m.DeviceID + "/" + Name + ".json" }
func (m *Manager) statusKey() string  { return "devices/" + m.DeviceID + "/" + Name + "-status.json" }

func (m *Manager) now() time.Time {
	if m.Now != nil {
		return m.Now()
	}
	return time.Now()
}

func (m *Manager) logf(format string, args ...any) {
	m.Logf(Name+": "+format, args...)
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
	m.loaded = true
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

// Run looks for the app's requests and the cameras plugged in, and fetches
// videos, until ctx ends.
func (m *Manager) Run(ctx context.Context) error {
	if !m.loaded {
		m.load()
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

// Step is one look for a request and the cameras plugged in, and a fetch
// when it's time or an added camera was just plugged in (Run's loop; Known
// loads the state first). The status is put when something changed.
func (m *Manager) Step(ctx context.Context) {
	req, err := m.request(ctx)
	if err != nil {
		m.logf("the request: %v", err)
	}
	plugged := m.plugged()
	m.detect(ctx)
	if req != nil && req.RequestedAt > m.state.Handled {
		m.handle(ctx, req)
	}
	// An added camera plugged in since the last look is fetched at once.
	for id := range m.plugged() {
		if !plugged[id] {
			m.lastFetch = time.Time{}
		}
	}
	if len(m.state.Cameras) > 0 && m.now().Sub(m.lastFetch) >= m.Every {
		m.fetch(ctx)
	}
	if m.dirty || !m.published {
		m.setStatus(ctx, Status{})
	}
}

// request is the app's request, opened; nil when there's none.
func (m *Manager) request(ctx context.Context) (*Request, error) {
	tmp, err := os.MkdirTemp(m.Dir, Name+"-req-")
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
	m.state.Handled = req.RequestedAt
	m.dirty = true
	defer func() {
		if err := m.save(); err != nil {
			m.logf("saving: %v", err)
		}
		if err := m.Store.Delete(ctx, m.requestKey()); err != nil {
			m.logf("deleting the request: %v", err)
		}
	}()
	switch {
	case req.Remove != "":
		if c, ok := m.state.Cameras[req.Remove]; ok {
			delete(m.state.Cameras, req.Remove)
			delete(m.errs, req.Remove)
			m.logf("%q removed; its device and events stay", c.Name)
			m.save()
			m.announce(ctx)
		}
	case req.Add != nil:
		m.add(ctx, req)
	}
}

func (m *Manager) add(ctx context.Context, req *Request) {
	serial := strings.TrimSpace(req.Add.Serial)
	if serial == "" {
		m.fail(ctx, req, "the camera's serial number is missing")
		return
	}
	model := ""
	for _, d := range m.detected {
		if d.Serial == serial {
			model = d.Model
		}
	}
	name := strings.TrimSpace(req.Add.Name)
	if name == "" {
		name = model
	}
	if name == "" {
		name = "USB camera"
	}
	c := Camera{Name: name, Model: model, Serial: serial}
	// The same camera again: its device and what was fetched stay.
	for id, old := range m.state.Cameras {
		if old.Serial == serial {
			c = old
			c.DeviceID, c.Name = id, name
			if model != "" {
				c.Model = model
			}
		}
	}
	if c.DeviceID == "" {
		c.DeviceID = m.NewDevice()
		// The first fetch goes back Backfill.
		c.Since = m.now().Add(-m.Backfill).Unix()
		m.logf("%q (%s %s) is device %s", name, model, serial, c.DeviceID)
	}
	m.state.Cameras[c.DeviceID] = c
	delete(m.errs, c.DeviceID)
	m.save()
	m.announce(ctx)
	m.lastFetch = time.Time{}
}

func (m *Manager) fail(ctx context.Context, req *Request, why string) {
	m.logf("%s", why)
	m.setStatus(ctx, Status{State: StateError, Error: why})
}

func (m *Manager) announce(ctx context.Context) {
	if m.Cameras == nil {
		return
	}
	if err := m.Cameras(ctx, m.cameraList()); err != nil {
		m.logf("registering the cameras: %v", err)
	}
}

// plugged are the added cameras plugged in, by device ID.
func (m *Manager) plugged() map[string]bool {
	out := map[string]bool{}
	for id, c := range m.state.Cameras {
		if m.port(c.Serial) != "" {
			out[id] = true
		}
	}
	return out
}

// port is where the camera with serial is plugged in ("" when it isn't).
func (m *Manager) port(serial string) string {
	for _, d := range m.detected {
		if d.Serial == serial {
			return d.Port
		}
	}
	return ""
}

// usbDevice is a USB device the kernel lists with a still-image interface.
type usbDevice struct {
	bus, dev                      int
	serial, manufacturer, product string
}

// stillImage lists the USB devices with a still-image interface (class 6:
// PTP, and MTP on most cameras); false when the kernel's list can't be
// read (then gphoto2 is asked every time).
func (m *Manager) stillImage() ([]usbDevice, bool) {
	entries, err := os.ReadDir(m.SysDir)
	if err != nil {
		return nil, false
	}
	read := func(dir, name string) string {
		data, _ := os.ReadFile(filepath.Join(dir, name))
		return strings.TrimSpace(string(data))
	}
	var out []usbDevice
	for _, e := range entries {
		// Devices are 1-1, 1-1.2 (usb1 the root hub); 1-1:1.0 their
		// interfaces.
		if strings.Contains(e.Name(), ":") {
			continue
		}
		dir := filepath.Join(m.SysDir, e.Name())
		ifaces, _ := filepath.Glob(filepath.Join(dir, e.Name()+":*", "bInterfaceClass"))
		still := false
		for _, f := range ifaces {
			if data, _ := os.ReadFile(f); strings.TrimSpace(string(data)) == "06" {
				still = true
			}
		}
		if !still {
			continue
		}
		bus, err1 := strconv.Atoi(read(dir, "busnum"))
		dev, err2 := strconv.Atoi(read(dir, "devnum"))
		if err1 != nil || err2 != nil {
			continue
		}
		out = append(out, usbDevice{bus: bus, dev: dev, serial: read(dir, "serial"),
			manufacturer: read(dir, "manufacturer"), product: read(dir, "product")})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].bus < out[j].bus || out[i].bus == out[j].bus && out[i].dev < out[j].dev
	})
	return out, true
}

// detect finds the cameras plugged in: cheap while nothing changes (the
// kernel's list read), gphoto2 asked when it does.
func (m *Manager) detect(ctx context.Context) {
	usb, known := m.stillImage()
	sig := fmt.Sprint(usb)
	if known && sig == m.usb && m.detectErr == "" {
		return
	}
	var detected []Detected
	detectErr := ""
	if !known || len(usb) > 0 {
		var err error
		detected, err = m.autoDetect(ctx, usb)
		if err != nil {
			detectErr = err.Error()
		}
	}
	m.usb = sig
	if fmt.Sprint(detected) != fmt.Sprint(m.detected) || detectErr != m.detectErr {
		if detectErr != m.detectErr && detectErr != "" {
			m.logf("detecting cameras: %s", detectErr)
		}
		for _, d := range detected {
			if !containsSerial(m.detected, d.Serial) {
				m.logf("%s (%s) plugged in at %s", d.Model, d.Serial, d.Port)
			}
		}
		m.detected, m.detectErr, m.dirty = detected, detectErr, true
	}
}

func containsSerial(ds []Detected, serial string) bool {
	for _, d := range ds {
		if d.Serial == serial {
			return true
		}
	}
	return false
}

var portPattern = regexp.MustCompile(`^usb:(\d+),(\d+)$`)

// autoDetect asks gphoto2 for the cameras plugged in (`--auto-detect`), and
// gives each its serial number: the kernel's, else the camera's summary.
func (m *Manager) autoDetect(ctx context.Context, usb []usbDevice) ([]Detected, error) {
	out, err := m.run(ctx, time.Minute, "--auto-detect")
	if err != nil {
		return nil, err
	}
	var detected []Detected
	rows := false
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "-----") {
			rows = true
			continue
		}
		fields := strings.Fields(line)
		if !rows || len(fields) < 2 {
			continue
		}
		port := fields[len(fields)-1]
		p := portPattern.FindStringSubmatch(port)
		if p == nil {
			continue
		}
		bus, _ := strconv.Atoi(p[1])
		dev, _ := strconv.Atoi(p[2])
		d := Detected{Model: strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(line), port)), Port: port}
		for _, u := range usb {
			if u.bus == bus && u.dev == dev {
				d.Serial = u.serial
			}
		}
		if d.Serial == "" {
			d.Serial = m.summarySerial(ctx, port)
		}
		if d.Serial == "" || containsSerial(detected, d.Serial) {
			m.logf("%s at %s has no serial number: it can't be added", d.Model, port)
			continue
		}
		detected = append(detected, d)
	}
	return detected, nil
}

// summarySerial is the serial number the camera's summary says ("" when
// it doesn't).
func (m *Manager) summarySerial(ctx context.Context, port string) string {
	out, err := m.run(ctx, time.Minute, "--port", port, "--summary")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(out, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "Serial Number:"); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// run runs gphoto2 (in English, for its output and errors are read) and
// returns what it printed. A camera another program holds is ErrBusy.
func (m *Manager) run(ctx context.Context, timeout time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := m.GPhoto2(ctx, args...)
	cmd.Env = append(os.Environ(), "LC_ALL=C", "LANG=C", "LANGUAGE=")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, fs.ErrNotExist) {
			return "", ErrNoGPhoto2
		}
		all := stdout.String() + stderr.String()
		if strings.Contains(all, "Could not claim the USB device") || strings.Contains(all, "Device or resource busy") {
			return "", ErrBusy
		}
		if ctx.Err() != nil {
			return "", fmt.Errorf("gphoto2 %s: timed out", args[len(args)-1])
		}
		return "", fmt.Errorf("gphoto2: %v: %s", err, lastLines(all, 2))
	}
	return stdout.String(), nil
}

// File is a file on a camera.
type File struct {
	// Folder is its folder ("/store_00010001/DCIM/100GOPRO").
	Folder, Name string
	// KB is its size (gphoto2 says it in KB), 0 when not known.
	KB int64
	// Time is its time (epoch seconds), 0 when not known.
	Time int64
}

// Path is its path on the camera.
func (f File) Path() string { return f.Folder + "/" + f.Name }

func (f File) sig() string { return fmt.Sprintf("%d:%d", f.KB, f.Time) }

// IsVideo says whether f is a video fetched: MP4 or MOV; not photos, nor a
// GoPro's low-resolution copies and thumbnails (.LRV, .THM).
func (f File) IsVideo() bool {
	switch strings.ToLower(path.Ext(f.Name)) {
	case ".mp4", ".mov":
		return true
	}
	return false
}

var (
	folderPattern = regexp.MustCompile(`^There (?:is|are) \d+ files? in folder '(.*)'\.$`)
	// #1     GOPR0002.MP4               rd 123456 KB video/mp4 1760443200
	filePattern = regexp.MustCompile(`^#\d+\s+(.+?)\s+[r-][d-](?:\s+(\d+) KB)?(?:\s+\d+x\d+)?(?:\s+([^\s]+/[^\s]+))?(?:\s+(-?\d+))?\s*$`)
	bareFile    = regexp.MustCompile(`^#\d+\s+(\S.*?)\s*$`)
)

// ParseFiles reads `gphoto2 --list-files`.
func ParseFiles(out string) []File {
	var files []File
	folder := ""
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if f := folderPattern.FindStringSubmatch(line); f != nil {
			folder = strings.TrimSuffix(f[1], "/")
			continue
		}
		if folder == "" && !strings.HasPrefix(line, "#") {
			continue
		}
		if f := filePattern.FindStringSubmatch(line); f != nil {
			kb, _ := strconv.ParseInt(f[2], 10, 64)
			at, _ := strconv.ParseInt(f[4], 10, 64)
			files = append(files, File{Folder: folder, Name: f[1], KB: kb, Time: at})
		} else if f := bareFile.FindStringSubmatch(line); f != nil {
			files = append(files, File{Folder: folder, Name: f[1]})
		}
	}
	return files
}

// fetch downloads each plugged-in camera's new videos and hands them over.
func (m *Manager) fetch(ctx context.Context) {
	m.lastFetch = m.now()
	m.dirty = true
	for _, c := range m.cameraList() {
		m.leftovers(ctx, c)
		port := m.port(c.Serial)
		if port == "" {
			// Unplugged: not an error, it's fetched once it's back.
			delete(m.errs, c.DeviceID)
			continue
		}
		if err := m.fetchCamera(ctx, c, port); err != nil {
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
}

// update keeps c (where fetching got to), at once: a restart doesn't fetch
// a video again.
func (m *Manager) update(c Camera) {
	if _, ok := m.state.Cameras[c.DeviceID]; ok {
		m.state.Cameras[c.DeviceID] = c
		if err := m.save(); err != nil {
			m.logf("saving: %v", err)
		}
	}
}

func (m *Manager) fetchCamera(ctx context.Context, c Camera, port string) error {
	out, err := m.run(ctx, 5*time.Minute, "--port", port, "--list-files")
	if err != nil {
		return err
	}
	files := ParseFiles(out)
	first := !c.Listed
	seen := map[string]string{}
	var videos []File
	for _, f := range files {
		if !f.IsVideo() {
			continue
		}
		seen[f.Path()] = c.Fetched[f.Path()]
		switch {
		case c.Fetched[f.Path()] == f.sig():
		case f.Time == 0 && first:
			// Without a time, on the first listing: taken as old.
			seen[f.Path()] = f.sig()
		case f.Time != 0 && f.Time < c.Since:
			// Older than the backfill: not fetched.
		default:
			videos = append(videos, f)
		}
	}
	// Those no longer on the camera are forgotten.
	c.Fetched, c.Listed = map[string]string{}, true
	for p, sig := range seen {
		if sig != "" {
			c.Fetched[p] = sig
		}
	}
	m.update(c)
	sort.SliceStable(videos, func(i, j int) bool { return videos[i].Time < videos[j].Time })
	for _, f := range videos {
		out, err := m.fetchVideo(ctx, c, port, f)
		if err != nil {
			return fmt.Errorf("%s: %w", f.Path(), err)
		}
		c.Fetched[f.Path()] = f.sig()
		m.update(c)
		if out == "" {
			continue
		}
		if err := m.Clip(ctx, c, out); err != nil {
			m.logf("%q: %s: %v", c.Name, f.Name, err)
		}
	}
	return nil
}

func (m *Manager) incoming(c Camera) string {
	return filepath.Join(m.Dir, Name+"-incoming", c.DeviceID)
}

// out is where a video is downloaded: named like the Pi's chunks, with
// its start in UTC (its file time; now when it has none).
func (m *Manager) out(c Camera, f File) string {
	start := m.now().UTC()
	if f.Time != 0 {
		start = time.Unix(f.Time, 0).UTC()
	}
	return filepath.Join(m.incoming(c), "rec-"+Name+"-"+start.Format("20060102T150405")+".mp4")
}

// fetchVideo downloads f, streamed to disk by gphoto2, and says where to
// ("" for a video bigger than MaxBytes: skipped). A download cut off is
// deleted and fails (it's tried again at the next fetch).
func (m *Manager) fetchVideo(ctx context.Context, c Camera, port string, f File) (string, error) {
	if m.MaxBytes > 0 && f.KB<<10 > m.MaxBytes {
		m.logf("%q: %s skipped, %d MB is too big", c.Name, f.Path(), f.KB>>10)
		return "", nil
	}
	if err := os.MkdirAll(m.incoming(c), 0o700); err != nil {
		return "", err
	}
	out := m.out(c, f)
	part := out + ".part"
	if _, err := m.run(ctx, time.Hour, "--port", port, "--get-file", f.Path(),
		"--filename", part, "--force-overwrite"); err != nil {
		os.Remove(part)
		return "", err
	}
	info, err := os.Stat(part)
	if err != nil {
		return "", fmt.Errorf("not downloaded: %w", err)
	}
	if n := info.Size(); f.KB > 0 && (n > f.KB<<10 || n <= (f.KB-1)<<10) {
		os.Remove(part)
		return "", fmt.Errorf("cut off: %d of %d KB downloaded", (n+1023)>>10, f.KB)
	}
	if err := os.Rename(part, out); err != nil {
		return "", err
	}
	m.logf("%q: %s fetched (%d MB)", c.Name, f.Path(), info.Size()>>20)
	return out, nil
}

// leftovers hands over the videos a stop left in the camera's incoming
// folder between their download and their hand-over, and deletes a
// download cut off (`.part`): it's fetched again.
func (m *Manager) leftovers(ctx context.Context, c Camera) {
	dir := m.incoming(c)
	files, _ := os.ReadDir(dir)
	for _, f := range files {
		file := filepath.Join(dir, f.Name())
		switch {
		case strings.HasSuffix(f.Name(), ".part"):
			os.Remove(file)
		case strings.HasPrefix(f.Name(), "rec-") && strings.HasSuffix(f.Name(), ".mp4"):
			if err := m.Clip(ctx, c, file); err != nil {
				m.logf("%q: %s: %v", c.Name, f.Name(), err)
			}
		}
	}
}

// setStatus publishes the status, sealed, with the cameras detected and
// added. Without a state given, it's ok (off with neither), or the
// detection's error.
func (m *Manager) setStatus(ctx context.Context, s Status) {
	s.RequestedAt = m.state.Handled
	s.Detected = m.detected
	plugged := m.plugged()
	for _, c := range m.cameraList() {
		s.Cameras = append(s.Cameras, StatusCamera{
			Name: c.Name, Model: c.Model, Serial: c.Serial, DeviceID: c.DeviceID,
			Plugged: plugged[c.DeviceID], LastFetch: m.fetched[c.DeviceID], Error: m.errs[c.DeviceID],
		})
	}
	switch {
	case s.State != "":
	case m.detectErr != "":
		s.State, s.Error = StateError, m.detectErr
	case len(s.Cameras) == 0 && len(s.Detected) == 0:
		s.State = StateOff
	default:
		s.State = StateOK
	}
	s.UpdatedAt = m.now().UnixMilli()
	plain := filepath.Join(m.Dir, Name+"-status.json")
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
		return
	}
	m.published, m.dirty = true, false
}

func lastLines(s string, n int) string {
	var lines []string
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " / ")
}
