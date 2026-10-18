package main

import (
	"context"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/rclone"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
	"github.com/prodbytes/presence/presence_streamer/internal/usbcam"
)

// startUSBCams starts the USB cameras' loop (specs/usb-cameras.md): it
// detects the still-image cameras plugged into this streamer, looks for
// the app's requests in its folder, and fetches each added camera's new
// videos into a pipeline of its own, as a device of its own. It returns
// its cameras' device IDs, which join the profile's devices at each
// renewal, and run, which starts the loop.
func startUSBCams(ctx context.Context, o *options, deviceID string, key []byte, sess *session.Session,
	folder *rclone.Folder, base *stream.Streamer, wg *sync.WaitGroup, cancel context.CancelCauseFunc,
	logf func(string, ...any)) (cameras func() []string, run func()) {
	pipelines := newCameraPipelines(ctx, base, filepath.Join(o.stateDir, "spool", usbcam.Name), usbcam.Name, "USB camera", wg, cancel, logf)
	set := func(cameras []usbcam.Camera) {
		refs := make([]cameraRef, len(cameras))
		for i, c := range cameras {
			refs[i] = cameraRef{DeviceID: c.DeviceID, Name: c.Name}
		}
		pipelines.set(refs, true)
	}
	m := &usbcam.Manager{
		Dir: o.stateDir, DeviceID: deviceID, Key: key, Store: folder,
		GPhoto2: func(ctx context.Context, args ...string) *exec.Cmd {
			return exec.CommandContext(ctx, o.gphoto2, args...)
		},
		SysDir:    "/sys/bus/usb/devices",
		NewDevice: ids.NewDevice,
		Cameras: func(ctx context.Context, cameras []usbcam.Camera) error {
			set(cameras)
			return sess.Register(ctx)
		},
		Clip: func(ctx context.Context, c usbcam.Camera, file string) error {
			return pipelines.clip(ctx, cameraRef{DeviceID: c.DeviceID, Name: c.Name}, file)
		},
		Poll:  30 * time.Second,
		Every: o.usbcamEvery, Backfill: 24 * time.Hour,
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
