package main

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/records"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// cameraRef is a camera this streamer fetches for (Blink's, GoPro's,
// Reolink's, USB ones): its device and its name; Motion its chunks through
// the streamer's motion filter (an unattended USB camera's).
type cameraRef struct {
	DeviceID, Name string
	Motion         bool
}

// cameraPipelines runs one chunk pipeline per fetched camera, each its own
// device: the Pi's own settings, but the camera's device ID, name and
// spool, and every clip kept (the cameras record on motion, or by hand),
// or, for a camera that records all along (an unattended USB camera),
// every clip with movement in it.
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
	motion  map[string]*atomic.Bool
}

func newCameraPipelines(ctx context.Context, base *stream.Streamer, spool, kind, os string,
	wg *sync.WaitGroup, cancel context.CancelCauseFunc, logf func(string, ...any)) *cameraPipelines {
	return &cameraPipelines{base: base, spool: spool, kind: kind, os: os, ctx: ctx, wg: wg,
		cancel: cancel, logf: logf, running: map[string]context.CancelFunc{}, motion: map[string]*atomic.Bool{}}
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
				delete(p.motion, id)
			}
		}
	}
	for _, c := range cameras {
		if p.running[c.DeviceID] != nil {
			p.motion[c.DeviceID].Store(c.Motion)
			continue
		}
		dir := filepath.Join(p.spool, c.DeviceID)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			p.logf("%s: %v", p.kind, err)
			continue
		}
		b := p.base
		motion := &atomic.Bool{}
		motion.Store(c.Motion)
		p.motion[c.DeviceID] = motion
		cam := &stream.Streamer{
			Spool: dir, Store: b.Store, Searcher: b.Searcher, Cloud: b.Cloud,
			Keyframes: b.Keyframes, Duration: b.Duration, Motion: b.Motion,
			// The streamer's motion filter, while the camera wants it.
			MotionMin: b.MotionMin, MotionFilter: motion.Load,
			Key: b.Key, DeviceID: c.DeviceID, ProfileID: b.ProfileID, UserID: b.UserID,
			// Its name is the events' camera name too, beside its device.
			Camera:      records.Camera{ID: p.kind, Label: c.Name, OS: p.os, Name: c.Name},
			Location:    b.Location,
			ObjectScore: b.ObjectScore, MaxSpool: b.MaxSpool, Logf: b.Logf,
			// The camera records only on motion (or, filtered, what moves is
			// worth keeping): every clip is kept.
			KeepAll: true,
			Publish: b.Publish,
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

// spooled is how much a camera's spool holds, in bytes.
func (p *cameraPipelines) spooled(deviceID string) int64 {
	var total int64
	_ = filepath.WalkDir(filepath.Join(p.spool, deviceID), func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if info, err := d.Info(); err == nil {
				total += info.Size()
			}
		}
		return nil
	})
	return total
}

// clip moves a fetched clip into its camera's spool.
func (p *cameraPipelines) clip(_ context.Context, c cameraRef, file string) error {
	p.set([]cameraRef{c}, false)
	return os.Rename(file, filepath.Join(p.spool, c.DeviceID, filepath.Base(file)))
}
