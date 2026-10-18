package presence

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The auth API's 403s: a free profile's and the device limit's are
// refusals; others (and 5xx) are errors that pass, retried.
func TestForbidden(t *testing.T) {
	const key = "psk_0123456789abcdefghijABCDEFGHIJ_-0123456789"
	var status int
	var answer string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		w.Write([]byte(answer))
	}))
	defer srv.Close()
	api := &API{BaseURL: srv.URL}
	for _, c := range []struct {
		status int
		answer string
		want   error
	}{
		{403, `{"error":"streamers are Premium only"}`, ErrFree},
		{403, `{"error":"this device is past your plan's device limit","reason":"deviceLimit","deviceLimit":2,"devices":["a_b_c","d_e_f"]}`, ErrDeviceLimit},
		{403, `{"error":"presence_user is required"}`, nil},
		{403, `not JSON`, nil},
		{500, `{"error":"streamers are Premium only"}`, nil},
		{503, `{"reason":"deviceLimit"}`, nil},
	} {
		status, answer = c.status, c.answer
		_, err := api.StreamCredentials(context.Background(), key, "automatic_paranoid_axolotl", "calm_quiet_otter")
		switch {
		case err == nil:
			t.Fatalf("HTTP %d %s: no error", c.status, c.answer)
		case c.want != nil && err != c.want:
			t.Fatalf("HTTP %d %s: %v, want %v", c.status, c.answer, err, c.want)
		case c.want == nil && (err == ErrFree || err == ErrDeviceLimit || err == ErrKeyRefused):
			t.Fatalf("HTTP %d %s: %v, want an error that passes", c.status, c.answer, err)
		}
	}
}
