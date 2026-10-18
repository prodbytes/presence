package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/presence"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/state"
)

func TestDetectInCloud(t *testing.T) {
	const mb = 1 << 20
	for _, c := range []struct {
		mode  string
		total int64
		cloud bool
	}{
		{"auto", 427 * mb, true},   // Pi Zero W (512 MB)
		{"auto", 922 * mb, true},   // Pi 3 (1 GB)
		{"auto", 1849 * mb, false}, // Pi 4 2 GB, as it reports itself
		{"auto", 7820 * mb, false}, // Pi 5 8 GB
		{"auto", 0, false},         // unknown
		{"local", 427 * mb, false},
		{"cloud", 7820 * mb, true},
	} {
		cloud, why, err := detectInCloud(c.mode, c.total)
		if err != nil || cloud != c.cloud || why == "" {
			t.Errorf("%s with %d MB: cloud %v (%q), %v", c.mode, c.total/mb, cloud, why, err)
		}
	}
	if _, _, err := detectInCloud("gpu", 0); err == nil {
		t.Error("an unknown mode taken")
	}
}

func TestMemTotal(t *testing.T) {
	// Linux only; elsewhere it's unknown (0).
	if total := memTotal(); total < 0 {
		t.Fatalf("memory %d", total)
	}
}

func TestChooseProfile(t *testing.T) {
	saved := &state.State{ProfileID: "saved_profile_id"}
	for _, c := range []struct {
		flag, saved, want string
		bad               bool
	}{
		{"given_profile_id", "", "given_profile_id", false},
		{"", "saved_profile_id", "saved_profile_id", false},
		{"", "", "", false}, // the account's, after the sign-in
		{"not a profile", "", "", true},
	} {
		saved.ProfileID = c.saved
		got, err := chooseProfile(&options{profile: c.flag}, saved)
		if got != c.want || (err != nil) != c.bad {
			t.Errorf("--profile %q, saved %q: %q, %v", c.flag, c.saved, got, err)
		}
	}
}

// leaseServer is the auth API's lease route, the profile led by leader
// (empty: none; "fail": it answers 500).
type leaseServer struct {
	mu     sync.Mutex
	leader string
	asked  int
}

func (l *leaseServer) set(leader string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.leader = leader
}

func (l *leaseServer) session(t *testing.T) *session.Session {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/auth/stream/lease" || r.Header.Get("Authorization") != "Bearer psk_good" {
			t.Errorf("%s %s", r.Method, r.URL.Path)
			w.WriteHeader(404)
			return
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != "calm_quiet_otter brave_little_lamp" {
			t.Errorf("lease body %q", body)
		}
		l.mu.Lock()
		defer l.mu.Unlock()
		l.asked++
		switch l.leader {
		case "fail":
			w.WriteHeader(500)
		case "":
			l.leader = "brave_little_lamp"
			fallthrough
		default:
			fmt.Fprintf(w, `{"leader":%t,"streamLeader":{"device":%q,"seenAt":1},"silenceMs":60}`,
				l.leader == "brave_little_lamp", l.leader)
		}
	}))
	t.Cleanup(srv.Close)
	return &session.Session{API: &presence.API{BaseURL: srv.URL}, StreamKey: "psk_good",
		ProfileID: "calm_quiet_otter", DeviceID: "brave_little_lamp"}
}

func fastLease(t *testing.T) {
	was := leaseEvery
	leaseEvery = 10 * time.Millisecond
	t.Cleanup(func() { leaseEvery = was })
}

func TestWaitsToLead(t *testing.T) {
	fastLease(t)
	l := &leaseServer{leader: "swift_gentle_fox"}
	sess := l.session(t)
	var said []string
	logf := func(f string, a ...any) { said = append(said, fmt.Sprintf(f, a...)) }
	go func() {
		time.Sleep(50 * time.Millisecond)
		// The leader is gone (deleted, or silent an hour).
		l.set("")
	}()
	if err := waitToLead(context.Background(), sess, logf); err != nil {
		t.Fatal(err)
	}
	if l.asked < 3 {
		t.Errorf("asked %d times", l.asked)
	}
	// Who leads said once, not at every ask.
	if len(said) != 2 || !strings.Contains(said[0], "swift_gentle_fox leads") || !strings.Contains(said[1], "leading") {
		t.Errorf("said %q", said)
	}

	// Stopped while waiting: no error to exit with.
	l.set("swift_gentle_fox")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if err := waitToLead(ctx, sess, logf); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("stopped: %v", err)
	}
}

func TestKeepsTheLeaseUntilAnotherLeads(t *testing.T) {
	fastLease(t)
	l := &leaseServer{leader: "brave_little_lamp"}
	sess := l.session(t)
	ctx, cancel := context.WithCancelCause(context.Background())
	defer cancel(nil)
	go func() {
		time.Sleep(50 * time.Millisecond)
		l.set("swift_gentle_fox")
	}()
	keepLease(ctx, sess, cancel, t.Logf)
	cause := context.Cause(ctx)
	var notLeader presence.NotLeaderError
	if !errors.As(cause, &notLeader) || notLeader.Leader.Device != "swift_gentle_fox" || !session.Standby(cause) {
		t.Errorf("cause %v", cause)
	}
}

func TestStopsStreamingWhenTheLeaseLapses(t *testing.T) {
	fastLease(t)
	// Leading, with leaders replaced after 60 ms of silence; then the
	// auth API can't be reached.
	l := &leaseServer{leader: "brave_little_lamp"}
	sess := l.session(t)
	ctx, cancel := context.WithCancelCause(context.Background())
	defer cancel(nil)
	go func() {
		time.Sleep(25 * time.Millisecond)
		l.set("fail")
	}()
	start := time.Now()
	keepLease(ctx, sess, cancel, t.Logf)
	if cause := context.Cause(ctx); !errors.Is(cause, session.ErrLeaseLapsed) || !session.Standby(cause) {
		t.Errorf("cause %v", cause)
	}
	if time.Since(start) > time.Second {
		t.Errorf("took %s", time.Since(start))
	}
}
