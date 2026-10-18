package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/blink"
	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/rclone"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// blinkpyVersion is the blinkpy installed for the Blink helper (in its own
// virtualenv in the state folder: Debian doesn't package it).
const blinkpyVersion = "0.25.9"

// startBlink starts the Blink loop (unless --blink off): it looks for the
// app's request in this streamer's folder, and once logged in fetches each
// Blink camera's clips into a pipeline of its own, as a device of its own
// (specs/streamer.md, "Blink cameras"). It returns its cameras' device IDs,
// which join the profile's devices at each renewal, and run, which starts
// the loop (both nil when off).
func startBlink(ctx context.Context, o *options, deviceID string, key []byte, sess *session.Session,
	folder *rclone.Folder, base *stream.Streamer, wg *sync.WaitGroup, cancel context.CancelCauseFunc,
	logf func(string, ...any)) (cameras func() []string, run func()) {
	if o.blink == "off" {
		return nil, nil
	}
	venv := filepath.Join(o.stateDir, "blink-venv")
	pipelines := newCameraPipelines(ctx, base, filepath.Join(o.stateDir, "spool", "blink"), "blink", "Blink", wg, cancel, logf)
	set := func(cameras []blink.Camera) {
		refs := make([]cameraRef, len(cameras))
		for i, c := range cameras {
			refs[i] = cameraRef{DeviceID: c.DeviceID, Name: c.Name}
		}
		// Only these: a camera removed stops, and leaves the devices
		// registered.
		pipelines.set(refs, true)
	}
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
			set(cameras)
			return sess.Register(ctx)
		},
		Clip: func(ctx context.Context, c blink.Camera, file string) error {
			return pipelines.clip(ctx, cameraRef{DeviceID: c.DeviceID, Name: c.Name}, file)
		},
		Poll:  30 * time.Second,
		Every: o.blinkEvery, Backfill: 24 * time.Hour, PINWait: 10 * time.Minute,
		Logf: logf,
	}
	// The cameras known from before: pipelines now, and devices of the
	// profile at the next renewal.
	set(b.Known())
	return pipelines.deviceIDs, func() {
		wg.Add(1)
		go func() {
			defer wg.Done()
			b.Run(ctx)
		}()
	}
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
