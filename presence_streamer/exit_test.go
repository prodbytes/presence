package main

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/prodbytes/presence/presence_streamer/internal/presence"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/state"
)

// The exit codes the service reads: 3 (free) and 2 (setup or the app
// needed) aren't restarted; 1 is.
func TestExitFor(t *testing.T) {
	quiet := func(string, ...any) {}
	for _, c := range []struct {
		err  error
		want int
	}{
		{nil, 0},
		{context.Canceled, 0},
		{session.ErrFree, exitFree},
		{presence.ErrFree, exitFree},
		{fmt.Errorf("renewing: %w", presence.ErrFree), exitFree},
		{presence.ErrDeviceLimit, exitUsage},
		{presence.ErrKeyRefused, exitUsage},
		{presence.ErrUnauthorized, exitUsage},
		{errors.New("POST /api/auth/stream/credentials: HTTP 403 presence_user is required"), exitError},
		{errors.New("POST /api/auth/stream/credentials: HTTP 503 "), exitError},
	} {
		s, err := state.Load(filepath.Join(t.TempDir(), "state"))
		if err != nil {
			t.Fatal(err)
		}
		if got := exitFor(c.err, s, quiet); got != c.want {
			t.Errorf("exitFor(%v) = %d, want %d", c.err, got, c.want)
		}
	}
}
