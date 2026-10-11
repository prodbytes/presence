package session

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/google"
	"github.com/prodbytes/presence/presence_streamer/internal/presence"
)

type fake struct {
	tier, profile string
	refreshes     int
	expires       time.Time
}

func (f *fake) server(t *testing.T) (*google.Client, *presence.API) {
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		f.refreshes++
		token := "h." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"42"}`)) + ".s"
		fmt.Fprintf(w, `{"id_token":%q}`, token)
	})
	mux.HandleFunc("/api/auth/profile", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"profile":%q}`, f.profile)
	})
	mux.HandleFunc("/api/auth/credentials", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","tier":%q,"bucket":"user-data-test"}`, f.tier)
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
	if f.refreshes != 1 || s.UserID() != "42" {
		t.Fatalf("refreshed %d times, user %q", f.refreshes, s.UserID())
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
