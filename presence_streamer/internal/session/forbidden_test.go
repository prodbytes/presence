package session

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/presence"
)

// A profile that turns free, or a device past the plan's limit, ends the
// run at the next renewal: the auth API answers a 403. Other 403s pass.
func TestForbiddenAtRenewal(t *testing.T) {
	now := time.Date(2026, 10, 18, 12, 0, 0, 0, time.UTC)
	var answer string
	mux := http.NewServeMux()
	mux.HandleFunc("/api/auth/stream/credentials", func(w http.ResponseWriter, r *http.Request) {
		if answer != "" {
			w.WriteHeader(403)
			w.Write([]byte(answer))
			return
		}
		w.Write([]byte(`{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","tier":"premium","bucket":"user-data-test","userId":"7"}`))
	})
	mux.HandleFunc("/cognito", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"Credentials":{"AccessKeyId":"AK","SecretKey":"SK","SessionToken":"ST","Expiration":%d}}`, now.Add(time.Hour).Unix())
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	api := &presence.API{BaseURL: srv.URL, CognitoURL: srv.URL + "/cognito"}
	ctx := context.Background()
	for _, c := range []struct {
		answer string
		want   error
	}{
		{`{"error":"streamers are Premium only"}`, ErrFree},
		{`{"error":"this device is past your plan's device limit","reason":"deviceLimit","deviceLimit":2,"devices":[]}`, presence.ErrDeviceLimit},
		{`{"error":"presence_user is required"}`, nil},
	} {
		answer = ""
		s := &Session{API: api, StreamKey: "psk_good", ProfileID: "p_q_r", DeviceID: "a_b_c", Now: func() time.Time { return now }}
		if _, err := s.AWS(ctx); err != nil {
			t.Fatal(err)
		}
		answer = c.answer
		now = now.Add(56 * time.Minute)
		_, err := s.AWS(ctx)
		if c.want == nil {
			if err == nil || Fatal(err) {
				t.Fatalf("%s: %v, want an error that passes", c.answer, err)
			}
			continue
		}
		if !errors.Is(err, c.want) || !Fatal(err) {
			t.Fatalf("%s: %v, want %v (fatal)", c.answer, err, c.want)
		}
	}
}
