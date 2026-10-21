// Package usbcam makes cameras plugged into the streamer by USB Presence
// devices (specs/usb-cameras.md): still-image cameras (USB interface class
// 6, PTP or MTP: a GoPro HERO5 to HERO8, most digital cameras), reached
// with libgphoto2's `gphoto2` command, no network and no address. One
// streamer of the profile, the one the app's Settings pick, detects the
// cameras plugged into it, and fetches the videos each one added recorded.
// Every camera added becomes a device of its own, with an ID made here,
// whose videos are cut into chunks (ffmpeg, copied) that go through the
// same chunk pipeline as the Pi's own recordings. A camera is known by its
// USB serial number, the same on any port and after a replug.
//
// A camera is unattended by default (it's left recording): its chunks
// without movement are deleted, not uploaded, and each video is deleted
// from the camera once it's downloaded whole, so its card doesn't fill up.
//
// The app and this streamer talk through the profile's folder, sealed with
// this streamer's media key (only the profile's devices hold it):
//
//   - devices/<streamer>/usbcam.json, the app's request: {"add": {"name",
//     "serial", "unattended"}}, {"set": {"deviceId", "unattended"}} or
//     {"remove": "<device ID>"}, and "requestedAt". Deleted once handled.
//   - devices/<streamer>/usbcam-status.json, this streamer's answer:
//     {"state", "error", "detected": [{"model", "serial", "port"}],
//     "cameras": [{"name", "model", "serial", "deviceId", "unattended",
//     "plugged", "lastFetch", "error"}], "requestedAt", "updatedAt"}.
//
// Here, in the state folder: usbcam-state.json (mode 600: the cameras,
// and the videos fetched from each), and usbcam-incoming/<device>/, the
// videos downloaded (video-<UTC start>.mp4) and their chunks
// (chunks-<UTC start>/rec-usbcam-<UTC start>.mp4) till the camera's
// pipeline takes them.
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
	"syscall"
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
	// Unattended is the camera's mode (Camera.Unattended); nil: on, or as
	// it was for a camera added again.
	Unattended *bool `json:"unattended,omitempty"`
}

// Set changes an added camera's mode.
type Set struct {
	DeviceID   string `json:"deviceId"`
	Unattended bool   `json:"unattended"`
}

// Request is the app's (devices/<streamer>/usbcam.json).
type Request struct {
	Add         *Add   `json:"add,omitempty"`
	Set         *Set   `json:"set,omitempty"`
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
	// Unattended (nil: on, the default) keeps only the chunks with
	// movement (the streamer's motion filter), and deletes each video from
	// the camera once it's downloaded whole. Off, every chunk is kept and
	// nothing on the camera is deleted.
	Unattended *bool `json:"unattended,omitempty"`
	// Got are the videos downloaded whole, their size checked, still on
	// the camera ("<KB>:<time>" as Fetched): the only ones ever deleted
	// from it, while unattended (a failure is tried again at each fetch).
	Got map[string]string `json:"got,omitempty"`
}

// IsUnattended says whether c is unattended (the default).
func (c Camera) IsUnattended() bool { return c.Unattended == nil || *c.Unattended }

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
	Name     string `json:"name"`
	Model    string `json:"model,omitempty"`
	Serial   string `json:"serial"`
	DeviceID string `json:"deviceId"`
	// Unattended is Camera.IsUnattended.
	Unattended bool   `json:"unattended"`
	Plugged    bool   `json:"plugged"`
	LastFetch  int64  `json:"lastFetch,omitempty"`
	Error      string `json:"error,omitempty"`
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
	// Clip hands a camera's chunk to its pipeline (it's moved).
	Clip func(ctx context.Context, camera Camera, file string) error
	// Split cuts a downloaded video into chunks in dir, named by their UTC
	// start (start is the video's): SplitVideo. nil: a video is one chunk.
	Split func(ctx context.Context, video, dir string, start time.Time) error
	// Spooled is how much a camera's spool holds (bytes). Chunks are
	// handed over while it holds less than half of MaxSpool (its pipeline
	// seals copies beside them), so the pipeline never drops one unsent
	// (stream.Streamer.Trim): the rest wait in incoming.
	Spooled  func(camera Camera) int64
	MaxSpool int64
	// Free is the room left on the state folder's disk. A video is
	// downloaded only when twice its size (it, then its chunks while it's
	// split) leaves MinFree; meanwhile the camera says it's waiting.
	Free    func() (int64, error)
	MinFree int64
	// Settle is how long a new video is watched before it's fetched: one
	// whose size changes (still being written) waits.
	Settle time.Duration
	// Poll is how often the request and the cameras plugged in are looked
	// for; Every how often videos are fetched; Backfill how far back a new
	// camera's first fetch goes.
	Poll, Every, Backfill time.Duration
	Now                   func() time.Time
	Logf                  func(string, ...any)

	state     saved
	loaded    bool
	lastFetch time.Time
	fetched   map[string]int64
	errs      map[string]string
	// listed is each camera's last listing: its videos' "<KB>:<time>".
	listed map[string]map[string]string
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
		m.fetched, m.errs, m.listed = map[string]int64{}, map[string]string{}, map[string]map[string]string{}
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
	// The chunks waiting for room in their pipelines, and what a stop
	// left, carry on.
	for _, c := range m.cameraList() {
		if err := m.drain(ctx, c); err != nil {
			m.logf("%q: %v", c.Name, err)
		}
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
	case req.Set != nil:
		if c, ok := m.state.Cameras[req.Set.DeviceID]; ok {
			on := req.Set.Unattended
			c.Unattended = &on
			m.state.Cameras[c.DeviceID] = c
			m.logf("%q: unattended %v", c.Name, on)
			m.save()
			m.announce(ctx)
		}
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
	if req.Add.Unattended != nil {
		on := *req.Add.Unattended
		c.Unattended = &on
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

func (m *Manager) listFiles(ctx context.Context, port string) ([]File, error) {
	out, err := m.run(ctx, 5*time.Minute, "--port", port, "--list-files")
	if err != nil {
		return nil, err
	}
	return ParseFiles(out), nil
}

func videoSigs(files []File) map[string]string {
	out := map[string]string{}
	for _, f := range files {
		if f.IsVideo() {
			out[f.Path()] = f.sig()
		}
	}
	return out
}

func (m *Manager) fetchCamera(ctx context.Context, c Camera, port string) error {
	files, err := m.listFiles(ctx, port)
	if err != nil {
		return err
	}
	first := !c.Listed
	seen := map[string]string{}
	got := map[string]string{}
	var videos []File
	for _, f := range files {
		if !f.IsVideo() {
			continue
		}
		seen[f.Path()] = c.Fetched[f.Path()]
		if sig := c.Got[f.Path()]; sig != "" && sig == f.sig() {
			got[f.Path()] = sig
		}
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
	c.Fetched, c.Got, c.Listed = map[string]string{}, got, true
	for p, sig := range seen {
		if sig != "" {
			c.Fetched[p] = sig
		}
	}
	m.update(c)

	// A video still being written grows: it's fetched once its size held
	// since the last listing (one Settle ago, or the last fetch's).
	last := m.listed[c.DeviceID]
	m.listed[c.DeviceID] = videoSigs(files)
	settled := true
	for _, f := range videos {
		if last == nil || last[f.Path()] != f.sig() {
			settled = false
		}
	}
	if !settled {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(m.Settle):
		}
		again, err := m.listFiles(ctx, port)
		if err != nil {
			return err
		}
		now := videoSigs(again)
		m.listed[c.DeviceID] = now
		kept := videos[:0]
		for _, f := range videos {
			if now[f.Path()] == f.sig() {
				kept = append(kept, f)
			} else {
				m.logf("%q: %s is still being written: fetched once it's done", c.Name, f.Path())
			}
		}
		videos = kept
	}

	// Unattended: the videos downloaded whole are deleted from the camera
	// (those a failure left, again).
	var deleteErr error
	deleteGot := func(f File) {
		if !c.IsUnattended() || c.Got[f.Path()] != f.sig() {
			return
		}
		if err := m.deleteVideo(ctx, port, f, files); err != nil {
			m.logf("%q: %v", c.Name, err)
			if deleteErr == nil {
				deleteErr = err
			}
			return
		}
		delete(c.Got, f.Path())
		m.update(c)
	}
	for _, f := range files {
		if f.IsVideo() {
			deleteGot(f)
		}
	}

	sort.SliceStable(videos, func(i, j int) bool { return videos[i].Time < videos[j].Time })
	for _, f := range videos {
		if err := m.room(f); err != nil {
			return err
		}
		if err := m.fetchVideo(ctx, c, port, f); err != nil {
			return fmt.Errorf("%s: %w", f.Path(), err)
		}
		// Downloaded whole: on the streamer's disk from here.
		c.Fetched[f.Path()] = f.sig()
		if f.KB > 0 {
			// Only a size checked lets it be deleted from the camera.
			c.Got[f.Path()] = f.sig()
		}
		m.update(c)
		deleteGot(f)
		// Split at once, so its room frees up.
		if err := m.drain(ctx, c); err != nil {
			m.logf("%q: %v", c.Name, err)
		}
	}
	return deleteErr
}

// room says whether f can be downloaded: twice its size (it, then its
// chunks while it's split) must leave MinFree on the disk.
func (m *Manager) room(f File) error {
	if m.Free == nil || f.KB == 0 {
		return nil
	}
	free, err := m.Free()
	if err != nil {
		return nil
	}
	need := 2*(f.KB<<10) + m.MinFree
	if free < need {
		return fmt.Errorf("waiting for room on the streamer: %s needs %d MB, %d MB free", f.Name, need>>20, free>>20)
	}
	return nil
}

// FreeSpace is the room left on dir's disk, for an unprivileged user.
func FreeSpace(dir string) (int64, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(dir, &st); err != nil {
		return 0, err
	}
	return int64(st.Bavail) * int64(st.Bsize), nil
}

// Sidecars are a video's own files beside it among files: a GoPro's
// low-resolution copy and thumbnail (GOPR0002.LRV and GOPR0002.THM beside
// GOPR0002.MP4; GL010002.LRV beside GH010002.MP4 or GX010002.MP4).
func Sidecars(video File, files []File) []File {
	stem := func(name string) string { return strings.ToUpper(strings.TrimSuffix(name, path.Ext(name))) }
	base := stem(video.Name)
	names := map[string]bool{base: true}
	if len(base) > 2 && (strings.HasPrefix(base, "GH") || strings.HasPrefix(base, "GX")) {
		names["GL"+base[2:]] = true
	}
	var out []File
	for _, f := range files {
		switch strings.ToLower(path.Ext(f.Name)) {
		case ".lrv", ".thm":
			if f.Folder == video.Folder && names[stem(f.Name)] {
				out = append(out, f)
			}
		}
	}
	return out
}

// deleteVideo deletes a video from the camera, with its sidecars first: a
// failure leaves the video, to be tried again.
func (m *Manager) deleteVideo(ctx context.Context, port string, f File, files []File) error {
	for _, s := range append(Sidecars(f, files), f) {
		// A path (with a dot: gphoto2 takes it as a file, not a range of
		// numbers, which deleting would shift).
		if _, err := m.run(ctx, time.Minute, "--port", port, "--delete-file", s.Path()); err != nil {
			return fmt.Errorf("couldn't delete %s from the camera: %w", s.Path(), err)
		}
	}
	m.logf("%s deleted from the camera", f.Path())
	return nil
}

func (m *Manager) incoming(c Camera) string {
	return filepath.Join(m.Dir, Name+"-incoming", c.DeviceID)
}

// In a camera's incoming folder: a video downloaded (video-<start>.mp4,
// <start> its UTC start), being split (split-<start>/), and split
// (chunks-<start>/, its chunks).
const (
	videoPrefix  = "video-"
	splitPrefix  = "split-"
	chunksPrefix = "chunks-"
)

// timeLayout is a file name's time, as the Pi's chunks'.
const timeLayout = "20060102T150405"

// ChunkName names a chunk starting at start: rec-usbcam-<UTC start>.mp4,
// as the Pi's own.
func ChunkName(start time.Time) string {
	return "rec-" + Name + "-" + start.UTC().Format(timeLayout) + ".mp4"
}

// stamp is a video's start for its names in incoming (its file time; now
// when it has none): a second later while another video has it.
func (m *Manager) stamp(c Camera, f File) string {
	start := m.now().UTC()
	if f.Time != 0 {
		start = time.Unix(f.Time, 0).UTC()
	}
	for {
		s := start.Format(timeLayout)
		_, err1 := os.Stat(filepath.Join(m.incoming(c), videoPrefix+s+".mp4"))
		_, err2 := os.Stat(filepath.Join(m.incoming(c), chunksPrefix+s))
		if os.IsNotExist(err1) && os.IsNotExist(err2) {
			return s
		}
		start = start.Add(time.Second)
	}
}

// fetchVideo downloads f, streamed to disk by gphoto2, into the camera's
// incoming folder. A download cut off is deleted and fails (it's tried
// again at the next fetch).
func (m *Manager) fetchVideo(ctx context.Context, c Camera, port string, f File) error {
	if err := os.MkdirAll(m.incoming(c), 0o700); err != nil {
		return err
	}
	out := filepath.Join(m.incoming(c), videoPrefix+m.stamp(c, f)+".mp4")
	part := out + ".part"
	if _, err := m.run(ctx, time.Hour, "--port", port, "--get-file", f.Path(),
		"--filename", part, "--force-overwrite"); err != nil {
		os.Remove(part)
		return err
	}
	info, err := os.Stat(part)
	if err != nil {
		return fmt.Errorf("not downloaded: %w", err)
	}
	if n := info.Size(); f.KB > 0 && (n > f.KB<<10 || n <= (f.KB-1)<<10) {
		os.Remove(part)
		return fmt.Errorf("cut off: %d of %d KB downloaded", (n+1023)>>10, f.KB)
	}
	if err := os.Rename(part, out); err != nil {
		return err
	}
	m.logf("%q: %s fetched (%d MB)", c.Name, f.Path(), info.Size()>>20)
	return nil
}

// drain takes a camera's downloads on to its pipeline: each video is split
// into chunks (deleted once they're all made), and the chunks handed over,
// oldest first, while its spool has room. A stop anywhere carries on at
// the next: a download or a split cut off is done again.
func (m *Manager) drain(ctx context.Context, c Camera) error {
	dir := m.incoming(c)
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	split := map[string]bool{}
	for _, e := range entries {
		name := e.Name()
		switch {
		case strings.HasSuffix(name, ".part"), strings.HasPrefix(name, splitPrefix):
			os.RemoveAll(filepath.Join(dir, name))
		case strings.HasPrefix(name, chunksPrefix):
			split[strings.TrimPrefix(name, chunksPrefix)] = true
		}
	}
	for _, e := range entries {
		name := e.Name()
		if !strings.HasPrefix(name, videoPrefix) || !strings.HasSuffix(name, ".mp4") {
			continue
		}
		stamp := strings.TrimSuffix(strings.TrimPrefix(name, videoPrefix), ".mp4")
		video := filepath.Join(dir, name)
		if split[stamp] {
			// Split already, before a stop kept it from being deleted.
			os.Remove(video)
			continue
		}
		if err := m.split(ctx, c, video, stamp); err != nil {
			return err
		}
	}
	return m.handOver(ctx, c)
}

// split cuts a video into chunks, made in split-<start>/, which becomes
// chunks-<start>/ once they're all there; then the video is deleted.
func (m *Manager) split(ctx context.Context, c Camera, video, stamp string) error {
	start, err := time.Parse(timeLayout, stamp)
	if err != nil {
		return fmt.Errorf("%s: %w", filepath.Base(video), err)
	}
	dir := m.incoming(c)
	tmp := filepath.Join(dir, splitPrefix+stamp)
	whole := func() error {
		os.RemoveAll(tmp)
		if err := os.MkdirAll(tmp, 0o700); err != nil {
			return err
		}
		return os.Rename(video, filepath.Join(tmp, ChunkName(start)))
	}
	if m.Split == nil {
		err = whole()
	} else {
		os.RemoveAll(tmp)
		if err := os.MkdirAll(tmp, 0o700); err != nil {
			return err
		}
		err = m.Split(ctx, video, tmp, start)
		if err != nil && ctx.Err() == nil {
			// Not one ffmpeg can cut: handed over whole (the pipeline
			// deletes one it can't read).
			m.logf("%q: %s can't be split (%v): handed over whole", c.Name, filepath.Base(video), err)
			err = whole()
		}
	}
	if err != nil {
		os.RemoveAll(tmp)
		return err
	}
	if err := os.Rename(tmp, filepath.Join(dir, chunksPrefix+stamp)); err != nil {
		return err
	}
	os.Remove(video)
	n, _ := filepath.Glob(filepath.Join(dir, chunksPrefix+stamp, "rec-*.mp4"))
	m.logf("%q: %s split into %d chunks", c.Name, filepath.Base(video), len(n))
	return nil
}

// handOver moves the chunks, oldest first, into the camera's pipeline while
// its spool holds less than half of MaxSpool (one at least when it's
// empty); the rest wait.
func (m *Manager) handOver(ctx context.Context, c Camera) error {
	dir := m.incoming(c)
	var spooled int64
	if m.Spooled != nil {
		spooled = m.Spooled(c)
	}
	give := func(chunk string) (bool, error) {
		info, err := os.Stat(chunk)
		if err != nil {
			return true, nil
		}
		if m.MaxSpool > 0 && spooled > 0 && spooled+info.Size() > m.MaxSpool/2 {
			return false, nil
		}
		if err := m.Clip(ctx, c, chunk); err != nil {
			return false, err
		}
		spooled += info.Size()
		return true, nil
	}
	// Videos an older version left whole, then each video's chunks.
	loose, _ := filepath.Glob(filepath.Join(dir, "rec-*.mp4"))
	dirs, _ := filepath.Glob(filepath.Join(dir, chunksPrefix+"*"))
	sort.Strings(loose)
	sort.Strings(dirs)
	for _, chunk := range loose {
		if ok, err := give(chunk); !ok {
			return err
		}
	}
	for _, d := range dirs {
		chunks, _ := filepath.Glob(filepath.Join(d, "rec-*.mp4"))
		sort.Strings(chunks)
		for _, chunk := range chunks {
			if ok, err := give(chunk); !ok {
				return err
			}
		}
		os.Remove(d)
	}
	return nil
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
			Name: c.Name, Model: c.Model, Serial: c.Serial, DeviceID: c.DeviceID, Unattended: c.IsUnattended(),
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
