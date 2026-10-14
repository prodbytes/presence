package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/blink"
	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/rclone"
	"github.com/prodbytes/presence/presence_streamer/internal/records"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// blinkpyVersion is the blinkpy installed for the Blink helper (in its own
// virtualenv in the state folder: Debian doesn't package it).
const blinkpyVersion = "0.25.9"

// startBlink starts the Blink loop (unless --blink off): it looks for the
// app's request in this streamer's folder, and once logged in fetches each
// Blink camera's clips into a pipeline of its own, as a device of its own
// (specs/streamer.md, "Blink cameras").
func startBlink(ctx context.Context, o *options, deviceID string, key []byte, sess *session.Session,
	folder *rclone.Folder, base *stream.Streamer, wg *sync.WaitGroup, cancel context.CancelCauseFunc,
	logf func(string, ...any)) {
	if o.blink == "off" {
		return
	}
	venv := filepath.Join(o.stateDir, "blink-venv")
	pipelines := &blinkPipelines{base: base, spool: filepath.Join(o.stateDir, "spool", "blink"),
		ctx: ctx, wg: wg, cancel: cancel, logf: logf, running: map[string]*stream.Streamer{}}
	b := &blink.Blink{
		Dir: o.stateDir, DeviceID: deviceID, Key: key, Store: folder,
		Helper: func(ctx context.Context, args ...string) *exec.Cmd {
			return exec.CommandContext(ctx, filepath.Join(venv, "bin", "python"),
				append([]string{"-I", o.blinkHelper}, args...)...)
		},
		Ensure: func(ctx context.Context) error {
			return ensureBlinkpy(ctx, o.python, venv, logf)
		},
		NewDevice: ids.NewDevice,
		Cameras: func(ctx context.Context, cameras []blink.Camera) error {
			pipelines.set(cameras)
			return sess.Register(ctx)
		},
		Clip:  pipelines.clip,
		Poll:  30 * time.Second,
		Every: o.blinkEvery, Backfill: 24 * time.Hour, PINWait: 10 * time.Minute,
		Logf: logf,
	}
	// The cameras known from before: pipelines now, and devices of the
	// profile at the next renewal.
	pipelines.set(b.Known())
	sess.Cameras = pipelines.deviceIDs
	wg.Add(1)
	go func() {
		defer wg.Done()
		b.Run(ctx)
	}()
}

// ensureBlinkpy installs blinkpy in its virtualenv the first time.
func ensureBlinkpy(ctx context.Context, python, venv string, logf func(string, ...any)) error {
	done := filepath.Join(venv, ".blinkpy-"+blinkpyVersion)
	if _, err := os.Stat(done); err == nil {
		return nil
	}
	logf("blink: installing blinkpy %s (once)", blinkpyVersion)
	for _, args := range [][]string{
		{python, "-m", "venv", venv},
		{filepath.Join(venv, "bin", "pip"), "install", "--disable-pip-version-check", "-q", "blinkpy==" + blinkpyVersion},
	} {
		if out, err := exec.CommandContext(ctx, args[0], args[1:]...).CombinedOutput(); err != nil {
			return &installError{err: err, out: string(out)}
		}
	}
	return os.WriteFile(done, nil, 0o600)
}

type installError struct {
	err error
	out string
}

func (e *installError) Error() string {
	return e.err.Error() + ": " + lastLines(e.out, 2) + " (is python3-venv installed?)"
}

func lastLines(s string, n int) string {
	var lines []string
	for _, l := range splitLines(s) {
		if l != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	out := ""
	for i, l := range lines {
		if i > 0 {
			out += " / "
		}
		out += l
	}
	return out
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

// blinkPipelines runs one chunk pipeline per Blink camera, each its own
// device: the Pi's own settings, but the camera's device ID, name and
// spool, and every clip kept (Blink records on motion already).
type blinkPipelines struct {
	base   *stream.Streamer
	spool  string
	ctx    context.Context
	wg     *sync.WaitGroup
	cancel context.CancelCauseFunc
	logf   func(string, ...any)

	mu      sync.Mutex
	running map[string]*stream.Streamer
	cameras map[string]blink.Camera
}

func (p *blinkPipelines) deviceIDs() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, 0, len(p.running))
	for id := range p.running {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// set starts a pipeline for each camera that has none.
func (p *blinkPipelines) set(cameras []blink.Camera) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cameras == nil {
		p.cameras = map[string]blink.Camera{}
	}
	for _, c := range cameras {
		p.cameras[c.DeviceID] = c
		if p.running[c.DeviceID] != nil {
			continue
		}
		dir := filepath.Join(p.spool, c.DeviceID)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			p.logf("blink: %v", err)
			continue
		}
		b := p.base
		cam := &stream.Streamer{
			Spool: dir, Store: b.Store, Searcher: b.Searcher, Cloud: b.Cloud,
			Keyframes: b.Keyframes, Duration: b.Duration, Motion: b.Motion,
			Key: b.Key, DeviceID: c.DeviceID, ProfileID: b.ProfileID, UserID: b.UserID,
			Camera:      records.Camera{ID: "blink", Label: c.Name, OS: "Blink"},
			Location:    b.Location,
			ObjectScore: b.ObjectScore, MaxSpool: b.MaxSpool, Logf: b.Logf,
		}
		p.running[c.DeviceID] = cam
		p.start(cam, dir)
	}
}

func (p *blinkPipelines) start(st *stream.Streamer, dir string) {
	p.wg.Add(2)
	// Its settings (the media key) first, as for the Pi's own device.
	go func() {
		defer p.wg.Done()
		for pause := 5 * time.Second; ; pause = min(2*pause, 2*time.Minute) {
			err := st.Settings(p.ctx, time.Now())
			if err == nil {
				return
			}
			if session.Fatal(err) {
				p.cancel(err)
				return
			}
			p.logf("blink: %s's settings: %v; trying again in %s", st.DeviceID, err, pause)
			select {
			case <-p.ctx.Done():
				return
			case <-time.After(pause):
			}
		}
	}()
	go func() {
		defer p.wg.Done()
		finished := func() []string {
			names, _ := filepath.Glob(filepath.Join(dir, "rec-*.mp4"))
			sort.Strings(names)
			return names
		}
		if err := st.Run(p.ctx, finished, session.Fatal); err != nil {
			p.cancel(err)
		}
	}()
}

// clip moves a fetched clip into its camera's spool.
func (p *blinkPipelines) clip(_ context.Context, c blink.Camera, file string) error {
	p.set([]blink.Camera{c})
	return os.Rename(file, filepath.Join(p.spool, c.DeviceID, filepath.Base(file)))
}
