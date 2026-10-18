package main

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/records"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// cameraRef is a camera this streamer fetches for (Blink's, GoPro's, Reolink's): its
// device and its name.
type cameraRef struct {
	DeviceID, Name string
}

// cameraPipelines runs one chunk pipeline per fetched camera, each its own
// device: the Pi's own settings, but the camera's device ID, name and
// spool, and every clip kept (the cameras record on motion, or by hand).
type cameraPipelines struct {
	base *stream.Streamer
	// spool holds a folder per camera; kind and os are what its events say
	// (cameraId, os).
	spool, kind, os string
	ctx             context.Context
	wg              *sync.WaitGroup
	cancel          context.CancelCauseFunc
	logf            func(string, ...any)

	mu      sync.Mutex
	running map[string]context.CancelFunc
}

func newCameraPipelines(ctx context.Context, base *stream.Streamer, spool, kind, os string,
	wg *sync.WaitGroup, cancel context.CancelCauseFunc, logf func(string, ...any)) *cameraPipelines {
	return &cameraPipelines{base: base, spool: spool, kind: kind, os: os, ctx: ctx, wg: wg,
		cancel: cancel, logf: logf, running: map[string]context.CancelFunc{}}
}

func (p *cameraPipelines) deviceIDs() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]string, 0, len(p.running))
	for id := range p.running {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// set starts a pipeline for each camera that has none; with only, it also
// stops those of the cameras not among them (removed).
func (p *cameraPipelines) set(cameras []cameraRef, only bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if only {
		keep := map[string]bool{}
		for _, c := range cameras {
			keep[c.DeviceID] = true
		}
		for id, stop := range p.running {
			if !keep[id] {
				stop()
				delete(p.running, id)
			}
		}
	}
	for _, c := range cameras {
		if p.running[c.DeviceID] != nil {
			continue
		}
		dir := filepath.Join(p.spool, c.DeviceID)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			p.logf("%s: %v", p.kind, err)
			continue
		}
		b := p.base
		cam := &stream.Streamer{
			Spool: dir, Store: b.Store, Searcher: b.Searcher, Cloud: b.Cloud,
			Keyframes: b.Keyframes, Duration: b.Duration, Motion: b.Motion,
			Key: b.Key, DeviceID: c.DeviceID, ProfileID: b.ProfileID, UserID: b.UserID,
			Camera:      records.Camera{ID: p.kind, Label: c.Name, OS: p.os},
			Location:    b.Location,
			ObjectScore: b.ObjectScore, MaxSpool: b.MaxSpool, Logf: b.Logf,
		}
		ctx, stop := context.WithCancel(p.ctx)
		p.running[c.DeviceID] = stop
		p.start(ctx, cam, dir)
	}
}

func (p *cameraPipelines) start(ctx context.Context, st *stream.Streamer, dir string) {
	p.wg.Add(2)
	// Its settings (the media key) first, as for the Pi's own device.
	go func() {
		defer p.wg.Done()
		for pause := 5 * time.Second; ; pause = min(2*pause, 2*time.Minute) {
			err := st.Settings(ctx, time.Now())
			if err == nil {
				return
			}
			if session.Fatal(err) {
				p.cancel(err)
				return
			}
			p.logf("%s: %s's settings: %v; trying again in %s", p.kind, st.DeviceID, err, pause)
			select {
			case <-ctx.Done():
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
		// A removed camera's pipeline stops (its context, not the
		// streamer's): that's no error.
		if err := st.Run(ctx, finished, session.Fatal); err != nil && p.ctx.Err() == nil && ctx.Err() == nil {
			p.cancel(err)
		}
	}()
}

// clip moves a fetched clip into its camera's spool.
func (p *cameraPipelines) clip(_ context.Context, c cameraRef, file string) error {
	p.set([]cameraRef{c}, false)
	return os.Rename(file, filepath.Join(p.spool, c.DeviceID, filepath.Base(file)))
}
