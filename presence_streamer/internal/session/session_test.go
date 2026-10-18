package session

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/google"
	"github.com/prodbytes/presence/presence_streamer/internal/presence"
)

type fake struct {
	tier, profile string
	refreshes     int
	streams       int
	exchanges     int
	expires       time.Time
}

func (f *fake) server(t *testing.T) (*google.Client, *presence.API) {
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		f.refreshes++
		token := "h." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"42"}`)) + ".s"
		fmt.Fprintf(w, `{"id_token":%q}`, token)
	})
	// The Google ID token for a Presence session token.
	mux.HandleFunc("/api/auth/session", func(w http.ResponseWriter, r *http.Request) {
		f.exchanges++
		var req struct {
			Provider, IDToken string
			Refresh           *bool
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Provider != "google" || !strings.HasPrefix(req.IDToken, "h.") || req.Refresh == nil || *req.Refresh {
			t.Errorf("session request %+v, %v", req, err)
			w.WriteHeader(401)
			return
		}
		fmt.Fprintf(w, `{"token":"pst","expiresAt":%d}`, time.Now().Add(time.Hour).Unix())
	})
	mux.HandleFunc("/api/auth/profile", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer pst" {
			w.WriteHeader(401)
			return
		}
		fmt.Fprintf(w, `{"profile":%q}`, f.profile)
	})
	mux.HandleFunc("/api/auth/credentials", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer pst" {
			w.WriteHeader(401)
			return
		}
		fmt.Fprintf(w, `{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","tier":%q,"bucket":"user-data-test"}`, f.tier)
	})
	mux.HandleFunc("/api/auth/stream/credentials", func(w http.ResponseWriter, r *http.Request) {
		f.streams++
		if r.Header.Get("Authorization") != "Bearer psk_good" {
			w.WriteHeader(401)
			return
		}
		fmt.Fprintf(w, `{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","tier":%q,"bucket":"user-data-test","userId":"7"}`, f.tier)
	})
	mux.HandleFunc("/cognito", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"Credentials":{"AccessKeyId":"AK","SecretKey":"SK","SessionToken":"ST","Expiration":%d}}`, f.expires.Unix())
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &google.Client{ID: "c", Secret: "s", Endpoints: google.Endpoints{Token: srv.URL + "/token"}},
		&presence.API{BaseURL: srv.URL, CognitoURL: srv.URL + "/cognito"}
}

func TestRenewsBeforeExpiry(t *testing.T) {
	now := time.Date(2026, 10, 11, 12, 0, 0, 0, time.UTC)
	f := &fake{tier: "premium", profile: "p_q_r", expires: now.Add(time.Hour)}
	g, api := f.server(t)
	s := &Session{Google: g, API: api, RefreshToken: "rt", ProfileID: "p_q_r", DeviceID: "a_b_c", Now: func() time.Time { return now }}
	ctx := context.Background()
	if aws, err := s.AWS(ctx); err != nil || aws.SessionToken != "ST" {
		t.Fatalf("%+v %v", aws, err)
	}
	s.AWS(ctx)
	if f.refreshes != 1 || s.UserID() != "42" || f.exchanges != 1 {
		t.Fatalf("refreshed %d times, %d session exchanges, user %q", f.refreshes, f.exchanges, s.UserID())
	}
	now = now.Add(56 * time.Minute)
	s.AWS(ctx)
	if f.refreshes != 2 {
		t.Fatalf("not renewed 4 minutes before expiry (%d)", f.refreshes)
	}
	if c, _ := s.Credentials(ctx); c.Bucket != "user-data-test" {
		t.Fatalf("credentials %+v", c)
	}
}

func TestFreeAndWrongProfile(t *testing.T) {
	f := &fake{tier: "free", profile: "p_q_r", expires: time.Now().Add(time.Hour)}
	g, api := f.server(t)
	s := &Session{Google: g, API: api, RefreshToken: "rt", ProfileID: "p_q_r", DeviceID: "a_b_c"}
	if _, err := s.AWS(context.Background()); !errors.Is(err, ErrFree) || !Fatal(err) {
		t.Fatalf("free: %v", err)
	}
	f.tier, f.profile = "premium", "x_y_z"
	_, err := s.AWS(context.Background())
	var wrong WrongProfileError
	if !errors.As(err, &wrong) || wrong.Got != "x_y_z" || !Fatal(err) {
		t.Fatalf("wrong profile: %v", err)
	}
	if Fatal(errors.New("network down")) {
		t.Fatal("a network error is fatal")
	}
}

func TestStreamKeyWithoutGoogle(t *testing.T) {
	now := time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)
	f := &fake{tier: "premium", expires: now.Add(time.Hour)}
	_, api := f.server(t)
	s := &Session{API: api, StreamKey: "psk_good", ProfileID: "p_q_r", DeviceID: "a_b_c", Now: func() time.Time { return now }}
	ctx := context.Background()
	aws, err := s.AWS(ctx)
	if err != nil || aws.AccessKeyID != "AK" {
		t.Fatalf("aws %+v, %v", aws, err)
	}
	if s.UserID() != "7" || f.refreshes != 0 || f.streams != 1 || f.exchanges != 0 {
		t.Fatalf("user %q, %d Google refreshes, %d stream calls, %d session exchanges", s.UserID(), f.refreshes, f.streams, f.exchanges)
	}
	// Renewed with the key too.
	now = now.Add(56 * time.Minute)
	f.expires = now.Add(time.Hour)
	if _, err := s.AWS(ctx); err != nil || f.streams != 2 {
		t.Fatalf("renewal: %v, %d stream calls", err, f.streams)
	}

	f.tier = "free"
	if _, err := CheckKey(ctx, api, "psk_good", "p_q_r", "a_b_c"); !errors.Is(err, ErrFree) || !Fatal(err) {
		t.Fatalf("free: %v", err)
	}
	if _, err := CheckKey(ctx, api, "psk_bad", "p_q_r", "a_b_c"); !errors.Is(err, presence.ErrKeyRefused) || !Fatal(err) {
		t.Fatalf("a refused key: %v", err)
	}
}

func TestAnotherLeaderIsStandbyNotTheEnd(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/auth/stream/credentials", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(409)
		w.Write([]byte(`{"error":"another streamer leads this profile","reason":"notLeader","streamLeader":{"device":"swift_gentle_fox","seenAt":1}}`))
	})
	mux.HandleFunc("/api/auth/stream/lease", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"leader":false,"streamLeader":{"device":"swift_gentle_fox","seenAt":1},"silenceMs":3600000}`))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	s := &Session{API: &presence.API{BaseURL: srv.URL}, StreamKey: "psk_good", ProfileID: "p_q_r", DeviceID: "calm_quiet_otter"}

	_, err := s.Credentials(context.Background())
	var notLeader presence.NotLeaderError
	if !errors.As(err, &notLeader) || notLeader.Leader.Device != "swift_gentle_fox" {
		t.Fatalf("credentials: %v", err)
	}
	// It stops streaming, and waits: not an exit.
	if !Standby(err) || !Fatal(err) {
		t.Errorf("standby %v, fatal %v", Standby(err), Fatal(err))
	}
	if Standby(ErrFree) || Standby(errors.New("network")) {
		t.Error("only another leader, or a lapsed lease, is standby")
	}
	lease, err := s.Lease(context.Background())
	if err != nil || lease.Leader || lease.StreamLeader.Device != "swift_gentle_fox" || lease.SilenceMs != 3600000 {
		t.Errorf("lease %+v, %v", lease, err)
	}
}

func TestLeaseSignedInWithGoogle(t *testing.T) {
	f := &fake{tier: "premium", profile: "p_q_r", expires: time.Now().Add(time.Hour)}
	g, api := f.server(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if r.URL.Path != "/api/auth/profile/stream-lease" || r.Header.Get("Authorization") != "Bearer pst" || string(body) != "calm_quiet_otter" {
			t.Errorf("%s %s %q", r.URL.Path, r.Header.Get("Authorization"), body)
		}
		w.Write([]byte(`{"leader":true,"streamLeader":{"device":"calm_quiet_otter","seenAt":1},"silenceMs":3600000}`))
	}))
	t.Cleanup(srv.Close)
	// The session exchange is the fake's; the lease, this server's.
	mux := http.NewServeMux()
	mux.Handle("/api/auth/profile/stream-lease", srv.Config.Handler)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		req, _ := http.NewRequest(r.Method, api.BaseURL+r.URL.Path, r.Body)
		req.Header = r.Header
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			w.WriteHeader(502)
			return
		}
		defer res.Body.Close()
		w.WriteHeader(res.StatusCode)
		io.Copy(w, res.Body)
	})
	both := httptest.NewServer(mux)
	t.Cleanup(both.Close)
	s := &Session{Google: g, API: &presence.API{BaseURL: both.URL}, RefreshToken: "r", ProfileID: "p_q_r", DeviceID: "calm_quiet_otter"}
	for range 2 {
		lease, err := s.Lease(context.Background())
		if err != nil || !lease.Leader {
			t.Fatalf("lease %+v, %v", lease, err)
		}
	}
}
