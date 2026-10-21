package main

import (
	"strings"
	"testing"

	"github.com/prodbytes/presence/presence_streamer/internal/session"
)

func TestLiveStage(t *testing.T) {
	for _, c := range []struct{ stage, api, want string }{
		{"", "https://presence.nu01.com", "prod"},
		{"", "https://rc.presence.nu01.com", "rc"},
		{"", "http://localhost:8080", "prod"},
		{"prod", "https://rc.presence.nu01.com", "prod"},
		{"rc", "https://presence.nu01.com", "rc"},
	} {
		if got, err := liveStage(c.stage, c.api); err != nil || got != c.want {
			t.Errorf("liveStage(%q, %q) = %q, %v; want %q", c.stage, c.api, got, err, c.want)
		}
	}
	if _, err := liveStage("dev", ""); err == nil {
		t.Error("stage dev taken")
	}
}

// Off, or set wrong, live sync is nil and says why; streaming goes on.
func TestLiveSyncOff(t *testing.T) {
	const identity = "us-east-1:0123abcd-0123-4567-89ab-0123456789ab"
	var said []string
	logf := func(f string, a ...any) { said = append(said, f) }
	for _, o := range []options{
		{iotEndpoint: ""},
		{iotEndpoint: "off"},
		{iotEndpoint: "abc-ats.iot.us-east-1.amazonaws.com", stage: "dev"},
		{iotEndpoint: "https://not/an/endpoint"},
	} {
		said = nil
		if live := liveSync(&o, "brave_quiet_fox", identity, make([]byte, 32), &session.Session{}, logf); live != nil {
			t.Errorf("%+v: on", o)
		}
		if len(said) != 1 || !strings.Contains(said[0], "off") {
			t.Errorf("%+v: said %v", o, said)
		}
	}
	o := options{iotEndpoint: "abc-ats.iot.us-east-1.amazonaws.com", api: "https://rc.presence.nu01.com"}
	if live := liveSync(&o, "brave_quiet_fox", identity, make([]byte, 32), &session.Session{}, logf); live == nil {
		t.Fatal("off")
	} else if !strings.HasPrefix(live.ClientID(), identity+"-brave_quiet_fox-") {
		t.Fatalf("client ID %s", live.ClientID())
	}
}
