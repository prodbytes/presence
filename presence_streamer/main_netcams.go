package main

import (
	"context"
	"path/filepath"
	"sync"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/netcam"
	"github.com/prodbytes/presence/presence_streamer/internal/rclone"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// startNetcam starts a kind's loop (GoPro's, Reolink's; specs/gopro.md,
// specs/reolink.md): it looks for the app's requests in this streamer's
// folder, and fetches each camera's new videos into a pipeline of its own,
// as a device of its own; os is what its events say. It returns its
// cameras' device IDs, which join the profile's devices at each renewal,
// and run, which starts the loop.
func startNetcam(ctx context.Context, kind netcam.Kind, os string, every time.Duration, o *options,
	deviceID string, key []byte, sess *session.Session, folder *rclone.Folder, base *stream.Streamer,
	wg *sync.WaitGroup, cancel context.CancelCauseFunc, logf func(string, ...any)) (cameras func() []string, run func()) {
	name := kind.Name()
	pipelines := newCameraPipelines(ctx, base, filepath.Join(o.stateDir, "spool", name), name, os, wg, cancel, logf)
	set := func(cameras []netcam.Camera) {
		refs := make([]cameraRef, len(cameras))
		for i, c := range cameras {
			refs[i] = cameraRef{DeviceID: c.DeviceID, Name: c.Name}
		}
		pipelines.set(refs, true)
	}
	m := &netcam.Manager{
		Kind: kind, Dir: o.stateDir, DeviceID: deviceID, Key: key, Store: folder,
		NewDevice: ids.NewDevice,
		Cameras: func(ctx context.Context, cameras []netcam.Camera) error {
			set(cameras)
			return sess.Register(ctx)
		},
		Clip: func(ctx context.Context, c netcam.Camera, file string) error {
			return pipelines.clip(ctx, cameraRef{DeviceID: c.DeviceID, Name: c.Name}, file)
		},
		Poll:  30 * time.Second,
		Every: every, Backfill: 24 * time.Hour,
		// A video never takes more than half the spool.
		MaxBytes: int64(o.spoolMaxMB) << 20 / 2,
		Logf:     logf,
	}
	// The cameras known from before: pipelines now, and devices of the
	// profile at the next renewal.
	set(m.Known())
	return pipelines.deviceIDs, func() {
		wg.Add(1)
		go func() {
			defer wg.Done()
			m.Run(ctx)
		}()
	}
}
