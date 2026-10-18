package main

import (
	"context"
	"path/filepath"
	"sync"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/gopro"
	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/rclone"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// startGoPro starts the GoPro loop (unless --gopro off): it looks for the
// app's requests in this streamer's folder, and fetches each GoPro camera's
// new videos into a pipeline of its own, as a device of its own
// (specs/gopro.md). It returns its cameras' device IDs, which join the
// profile's devices at each renewal, and run, which starts the loop (both
// nil when off).
func startGoPro(ctx context.Context, o *options, deviceID string, key []byte, sess *session.Session,
	folder *rclone.Folder, base *stream.Streamer, wg *sync.WaitGroup, cancel context.CancelCauseFunc,
	logf func(string, ...any)) (cameras func() []string, run func()) {
	if o.gopro == "off" {
		return nil, nil
	}
	pipelines := newCameraPipelines(ctx, base, filepath.Join(o.stateDir, "spool", "gopro"), "gopro", "GoPro", wg, cancel, logf)
	set := func(cameras []gopro.Camera) {
		refs := make([]cameraRef, len(cameras))
		for i, c := range cameras {
			refs[i] = cameraRef{DeviceID: c.DeviceID, Name: c.Name}
		}
		pipelines.set(refs, true)
	}
	g := &gopro.GoPro{
		Dir: o.stateDir, DeviceID: deviceID, Key: key, Store: folder,
		NewDevice: ids.NewDevice,
		Cameras: func(ctx context.Context, cameras []gopro.Camera) error {
			set(cameras)
			return sess.Register(ctx)
		},
		Clip: func(ctx context.Context, c gopro.Camera, file string) error {
			return pipelines.clip(ctx, cameraRef{DeviceID: c.DeviceID, Name: c.Name}, file)
		},
		Poll:  30 * time.Second,
		Every: o.goproEvery, Backfill: 24 * time.Hour,
		Full: o.goproVideo == "full",
		// A video never takes more than half the spool.
		MaxBytes: int64(o.spoolMaxMB) << 20 / 2,
		Logf:     logf,
	}
	// The cameras known from before: pipelines now, and devices of the
	// profile at the next renewal.
	set(g.Known())
	return pipelines.deviceIDs, func() {
		wg.Add(1)
		go func() {
			defer wg.Done()
			g.Run(ctx)
		}()
	}
}
