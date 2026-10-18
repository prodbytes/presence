package livesync

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

const identity = "us-east-1:0123abcd-0123-4567-89ab-0123456789ab"

func TestParsePing(t *testing.T) {
	good := `{"v":1,"kind":"ping","deviceId":"brave_quiet_fox","identityId":"` + identity + `","sentAt":1791234567890,"nonce":"abcdef0123456789"}`
	m, err := parsePing([]byte(good), identity)
	if err != nil || m.DeviceID != "brave_quiet_fox" || m.SentAt != 1791234567890 || m.Nonce != "abcdef0123456789" {
		t.Fatalf("good ping: %+v %v", m, err)
	}
	sync := `{"v":1,"kind":"sync","deviceId":"brave_quiet_fox","identityId":"` + identity + `","sentAt":1}`
	if _, err := parsePing([]byte(sync), identity); !errors.Is(err, errNotPing) {
		t.Fatalf("sync: %v", err)
	}
	with := func(from, to string) string { return strings.Replace(good, from, to, 1) }
	for name, payload := range map[string]string{
		"not JSON":          "ping",
		"an array":          `[1]`,
		"null":              `null`,
		"two values":        good + good,
		"over 1 KB":         with(`"v":1`, `"v":1,"pad":"`+strings.Repeat("x", 1024)+`"`),
		"other version":     with(`"v":1`, `"v":2`),
		"version a string":  with(`"v":1`, `"v":"1"`),
		"no version":        with(`"v":1,`, ``),
		"pong":              with(`"ping"`, `"pong"`),
		"other identity":    with(identity, "us-east-1:ffffffff-0123-4567-89ab-0123456789ab"),
		"unsafe device":     with("brave_quiet_fox", "../x"),
		"device with ..":    with("brave_quiet_fox", "a..b"),
		"device not string": with(`"brave_quiet_fox"`, `5`),
		"sentAt a string":   with(`1791234567890`, `"1791234567890"`),
		"sentAt fractional": with(`1791234567890`, `1.5`),
		"no nonce":          with(`,"nonce":"abcdef0123456789"`, ``),
		"short nonce":       with(`abcdef0123456789`, `abc`),
		"nonce with symbol": with(`abcdef0123456789`, `abcdef01234567/9`),
	} {
		if _, err := parsePing([]byte(payload), identity); err == nil || errors.Is(err, errNotPing) {
			t.Errorf("%s: taken (%v)", name, err)
		}
	}
}

func TestSafeID(t *testing.T) {
	for id, want := range map[string]bool{
		"brave_quiet_fox":        true,
		"e-1.2:3":                true,
		"":                       false,
		"a/b":                    false,
		"a..b":                   false,
		strings.Repeat("a", 129): false,
	} {
		if SafeID(id) != want {
			t.Errorf("SafeID(%q) != %v", id, want)
		}
	}
}

func TestEventMessageShape(t *testing.T) {
	l, err := New(Config{Endpoint: "abc123-ats.iot.us-east-1.amazonaws.com", Stage: "prod", IdentityID: identity,
		DeviceID: "brave_quiet_fox", MediaKey: "a2V5", Credentials: noCredentials})
	if err != nil {
		t.Fatal(err)
	}
	event := `{"id":"e1","type":"clip_requested","time":5,"clipId":"c1"}`
	if !l.PublishEvent([]byte(event), "events/year=2026/day=279/e1.json", strings.Repeat("a", 32)) {
		t.Fatal("not queued")
	}
	var m map[string]any
	if err := json.Unmarshal(<-l.outbox, &m); err != nil {
		t.Fatal(err)
	}
	if m["v"] != 1.0 || m["kind"] != "event" || m["deviceId"] != "brave_quiet_fox" || m["identityId"] != identity ||
		m["key"] != "events/year=2026/day=279/e1.json" || m["etag"] != strings.Repeat("a", 32) || m["mediaKey"] != "a2V5" {
		t.Fatalf("envelope: %v", m)
	}
	if _, ok := m["sentAt"].(float64); !ok {
		t.Fatalf("sentAt: %v", m["sentAt"])
	}
	if e := m["event"].(map[string]any); e["id"] != "e1" || e["time"] != 5.0 {
		t.Fatalf("event: %v", e)
	}
	if _, ok := m["clip"]; ok {
		t.Fatal("a clip in a premium profile's message")
	}
	// Refused: not an object, a bad ETag, too big.
	if l.PublishEvent([]byte(`[1]`), "k", "") || l.PublishEvent([]byte(event), "k", "nothex") ||
		l.PublishEvent([]byte(`{"x":"`+strings.Repeat("a", MaxMessage)+`"}`), "k", "") {
		t.Fatal("a bad event queued")
	}
}

func TestNewRefusesBadConfig(t *testing.T) {
	base := Config{Endpoint: "abc123-ats.iot.us-east-1.amazonaws.com", Stage: "prod", IdentityID: identity,
		DeviceID: "brave_quiet_fox", Credentials: noCredentials}
	for name, change := range map[string]func(*Config){
		"endpoint with a path": func(c *Config) { c.Endpoint = "abc/mqtt" },
		"http endpoint":        func(c *Config) { c.Endpoint = "http://abc" },
		"remote ws":            func(c *Config) { c.Endpoint = "ws://example.com:4566" },
		"stage":                func(c *Config) { c.Stage = "dev" },
		"identity":             func(c *Config) { c.IdentityID = "x" },
		"device":               func(c *Config) { c.DeviceID = "a/b" },
		"no credentials":       func(c *Config) { c.Credentials = nil },
	} {
		c := base
		change(&c)
		if _, err := New(c); err == nil {
			t.Errorf("%s: taken", name)
		}
	}
	local := base
	local.Endpoint = "ws://localhost:4566"
	if l, err := New(local); err != nil || l.scheme != "ws" || l.host != "localhost:4566" {
		t.Errorf("local: %v", err)
	}
}

func TestRegionOf(t *testing.T) {
	if r := RegionOf("abc-ats.iot.eu-west-1.amazonaws.com", identity); r != "eu-west-1" {
		t.Error(r)
	}
	if r := RegionOf("ws://localhost:4566", identity); r != "us-east-1" {
		t.Error(r)
	}
}

func TestRetryDelay(t *testing.T) {
	l := &Live{cfg: Config{MinRetry: 1, MaxRetry: 10}}
	for failures, want := range map[int]int{1: 1, 2: 2, 3: 4, 4: 8, 5: 10, 50: 10} {
		if got := l.retryDelay(failures); int(got) != want {
			t.Errorf("retryDelay(%d) = %d, want %d", failures, got, want)
		}
	}
}
