package livesync

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/mqtt/mqtttest"
	"github.com/prodbytes/presence/presence_streamer/internal/sigv4"
	"github.com/prodbytes/presence/presence_streamer/internal/ws/wstest"
)

func noCredentials(context.Context) (sigv4.Credentials, error) {
	return sigv4.Credentials{}, errors.New("none")
}

// fakeIoT is AWS IoT's WebSocket endpoint in miniature: an HTTPS server
// that upgrades /mqtt to a WebSocket and speaks MQTT with a fake broker.
type fakeIoT struct {
	broker *mqtttest.Broker
	host   string
	tls    *tls.Config
	// urls gets each request's URL; refuse answers that many with 403.
	urls   chan *url.URL
	refuse atomic.Int32
}

func newFakeIoT(t *testing.T) *fakeIoT {
	t.Helper()
	f := &fakeIoT{broker: mqtttest.New(), urls: make(chan *url.URL, 64)}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.urls <- r.URL
		if f.refuse.Load() > 0 {
			f.refuse.Add(-1)
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		if r.URL.Path != "/mqtt" {
			http.NotFound(w, r)
			return
		}
		c, err := wstest.Upgrade(w, r, "mqtt")
		if err != nil {
			return
		}
		f.broker.Serve(c)
	}))
	t.Cleanup(srv.Close)
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	f.host = strings.TrimPrefix(srv.URL, "https://")
	f.tls = &tls.Config{RootCAs: pool}
	return f
}

// session waits for the broker's next connection.
func (f *fakeIoT) session(t *testing.T) *mqtttest.Session {
	t.Helper()
	select {
	case s := <-f.broker.Sessions:
		return s
	case <-time.After(10 * time.Second):
		t.Fatal("no connection")
	}
	return nil
}

// logs collects what's logged.
type logs struct {
	mu    sync.Mutex
	lines []string
}

func (l *logs) logf(format string, args ...any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines = append(l.lines, fmt.Sprintf(format, args...))
}

func (l *logs) text() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return strings.Join(l.lines, "\n")
}

const (
	accessKey = "AKIDEXAMPLE"
	secretKey = "SECRETKEYwJalrXUtnFEMI"
	token     = "SESSIONTOKEN/xyz+="
)

// start runs a Live against f until the test ends.
func start(t *testing.T, f *fakeIoT, change func(*Config)) (*Live, *logs, *atomic.Int32) {
	t.Helper()
	var calls atomic.Int32
	log := &logs{}
	cfg := Config{
		Endpoint: f.host, Region: "us-east-1", Stage: "prod", IdentityID: identity,
		DeviceID: "brave_quiet_fox", MediaKey: "a2V5",
		Credentials: func(context.Context) (sigv4.Credentials, error) {
			calls.Add(1)
			return sigv4.Credentials{AccessKeyID: accessKey, SecretKey: secretKey, SessionToken: token,
				Expiration: time.Now().Add(time.Hour)}, nil
		},
		Logf: log.logf, TLS: f.tls,
		MinRetry: 20 * time.Millisecond, MaxRetry: 100 * time.Millisecond, ConnectTimeout: 5 * time.Second,
	}
	if change != nil {
		change(&cfg)
	}
	l, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		l.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("Run didn't end")
		}
		// Never a secret in the log.
		for _, secret := range []string{secretKey, token, "SESSIONTOKEN", "X-Amz-Signature", "X-Amz-Security-Token"} {
			if strings.Contains(log.text(), secret) {
				t.Errorf("the log has %q:\n%s", secret, log.text())
			}
		}
	})
	return l, log, &calls
}

func published(t *testing.T, s *mqtttest.Session) mqtttest.Message {
	t.Helper()
	select {
	case m := <-s.Published:
		return m
	case <-time.After(10 * time.Second):
		t.Fatal("nothing published")
	}
	return mqtttest.Message{}
}

func nothingPublished(t *testing.T, s *mqtttest.Session) {
	t.Helper()
	select {
	case m := <-s.Published:
		t.Fatalf("published %s: %s", m.Topic, m.Payload)
	case <-time.After(300 * time.Millisecond):
	}
}

func ping(deviceID, nonce string, sentAt time.Time) []byte {
	b, _ := json.Marshal(map[string]any{"v": 1, "kind": "ping", "deviceId": deviceID, "identityId": identity,
		"sentAt": sentAt.UnixMilli(), "nonce": nonce})
	return b
}

// The whole round: a presigned connection, the subscription, an event
// published, a ping answered, and a reconnection after a drop.
func TestEndToEnd(t *testing.T) {
	f := newFakeIoT(t)
	l, log, _ := start(t, f, nil)

	u := <-f.urls
	q := u.Query()
	if q.Get("X-Amz-Algorithm") != "AWS4-HMAC-SHA256" || !strings.HasPrefix(q.Get("X-Amz-Credential"), accessKey+"/") ||
		!strings.HasSuffix(q.Get("X-Amz-Credential"), "/us-east-1/iotdevicegateway/aws4_request") ||
		q.Get("X-Amz-SignedHeaders") != "host" || len(q.Get("X-Amz-Signature")) != 64 || q.Get("X-Amz-Security-Token") != token {
		t.Fatalf("not presigned: %v", q)
	}
	s := f.session(t)
	if !strings.HasPrefix(s.ClientID, identity+"-brave_quiet_fox-") || len(s.ClientID) != len(identity)+len("-brave_quiet_fox-")+6 || !s.Clean {
		t.Fatalf("client ID %q, clean %v", s.ClientID, s.Clean)
	}
	if topic := <-s.Subscribed; topic != "presence/prod/"+identity+"/requests" {
		t.Fatalf("subscribed to %s", topic)
	}

	// An event.
	if !l.PublishEvent([]byte(`{"id":"e1","type":"clip_requested","time":5}`), "events/year=1970/day=001/e1.json", "") {
		t.Fatal("not queued")
	}
	m := published(t, s)
	if m.Topic != "presence/prod/"+identity+"/events" || m.QoS != 1 || m.Retain {
		t.Fatalf("event on %s, QoS %d", m.Topic, m.QoS)
	}
	var event map[string]any
	json.Unmarshal(m.Payload, &event)
	if event["kind"] != "event" || event["deviceId"] != "brave_quiet_fox" || event["event"].(map[string]any)["id"] != "e1" {
		t.Fatalf("event %s", m.Payload)
	}

	// A ping, answered on acks with its nonce.
	requests := "presence/prod/" + identity + "/requests"
	s.Send(requests, ping("calm_other_otter", "nonce0123456789", time.Now()), 1)
	m = published(t, s)
	var pong map[string]any
	json.Unmarshal(m.Payload, &pong)
	if m.Topic != "presence/prod/"+identity+"/acks" || pong["kind"] != "pong" || pong["v"] != 1.0 ||
		pong["deviceId"] != "brave_quiet_fox" || pong["identityId"] != identity || pong["nonce"] != "nonce0123456789" {
		t.Fatalf("pong on %s: %s", m.Topic, m.Payload)
	}
	if _, ok := pong["sentAt"].(float64); !ok {
		t.Fatalf("pong without sentAt: %s", m.Payload)
	}
	// Not again within 5 s, nor to its own, an old or a malformed ping, or
	// a Sync request; and it stays connected.
	s.Send(requests, ping("third_other_owl", "nonceABCDEFGH", time.Now()), 1)
	s.Send(requests, []byte(`{"v":1,"kind":"sync","deviceId":"calm_other_otter","identityId":"`+identity+`","sentAt":1}`), 1)
	s.Send(requests, []byte(`not json`), 0)
	nothingPublished(t, s)
	if !l.Connected() || l.Pongs() != 1 {
		t.Fatalf("connected %v, pongs %d", l.Connected(), l.Pongs())
	}
	if !strings.Contains(log.text(), "malformed presence message") {
		t.Fatalf("no malformed message logged:\n%s", log.text())
	}

	// Dropped by the server: it connects again (a new URL), and publishes.
	s.Close()
	<-f.urls
	s = f.session(t)
	<-s.Subscribed
	l.PublishEvent([]byte(`{"id":"e2","time":6}`), "k2", "")
	if m := published(t, s); !strings.Contains(string(m.Payload), `"e2"`) {
		t.Fatalf("after the reconnection: %s", m.Payload)
	}
	// Counted once the broker's PUBACK is in, which can be just after the
	// broker has the message.
	for deadline := time.Now().Add(5 * time.Second); l.Sent() != 2 && time.Now().Before(deadline); {
		time.Sleep(10 * time.Millisecond)
	}
	if l.Sent() != 2 {
		t.Fatalf("sent %d", l.Sent())
	}
	if !strings.Contains(log.text(), "disconnected") {
		t.Fatalf("the drop isn't logged:\n%s", log.text())
	}
}

func TestPingRules(t *testing.T) {
	f := newFakeIoT(t)
	start(t, f, nil)
	s := f.session(t)
	<-s.Subscribed
	requests := "presence/prod/" + identity + "/requests"
	// Its own, and one 3 min old: not answered.
	s.Send(requests, ping("brave_quiet_fox", "nonce0123456789", time.Now()), 1)
	s.Send(requests, ping("calm_other_otter", "nonce0123456789", time.Now().Add(-3*time.Minute)), 1)
	nothingPublished(t, s)
	// One from the future (a clock ahead) is.
	s.Send(requests, ping("calm_other_otter", "nonce0123456789", time.Now().Add(time.Hour)), 1)
	if m := published(t, s); !strings.HasSuffix(m.Topic, "/acks") {
		t.Fatalf("on %s", m.Topic)
	}
}

func TestRenewsBeforeTheCredentialsExpire(t *testing.T) {
	f := newFakeIoT(t)
	_, _, calls := start(t, f, func(c *Config) {
		c.RenewBefore = time.Hour
		first := true
		c.Credentials = func(context.Context) (sigv4.Credentials, error) {
			// The first expire 300 ms after the renewal's margin; the next
			// ones later.
			exp := time.Now().Add(2 * time.Hour)
			if first {
				exp = time.Now().Add(time.Hour + 300*time.Millisecond)
				first = false
			}
			return sigv4.Credentials{AccessKeyID: accessKey, SecretKey: secretKey, SessionToken: token, Expiration: exp}, nil
		}
	})
	s := f.session(t)
	second := f.session(t)
	select {
	case <-s.Disconnected:
	case <-time.After(5 * time.Second):
		t.Fatal("the old connection wasn't closed")
	}
	if second == s {
		t.Fatal("the same session")
	}
	// No third: the new credentials last.
	select {
	case <-f.broker.Sessions:
		t.Fatal("renewed again at once")
	case <-time.After(300 * time.Millisecond):
	}
	_ = calls
}

func TestBacksOffWhileRefused(t *testing.T) {
	f := newFakeIoT(t)
	f.refuse.Store(3)
	_, log, calls := start(t, f, nil)
	s := f.session(t)
	<-s.Subscribed
	if calls.Load() != 4 {
		t.Fatalf("credentials asked %d times, want a fresh set per attempt (4)", calls.Load())
	}
	text := log.text()
	if !strings.Contains(text, "live sync failed (1 in a row") || !strings.Contains(text, "403") {
		t.Fatalf("the failure isn't logged:\n%s", text)
	}
}

func TestBrokerRefusalAndCredentialFailures(t *testing.T) {
	f := newFakeIoT(t)
	f.broker.Refuse = 5
	var fail atomic.Bool
	fail.Store(true)
	_, log, _ := start(t, f, func(c *Config) {
		inner := c.Credentials
		c.Credentials = func(ctx context.Context) (sigv4.Credentials, error) {
			if fail.Swap(false) {
				return sigv4.Credentials{}, errors.New("the auth API is down")
			}
			return inner(ctx)
		}
	})
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(log.text(), "not authorized") && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !strings.Contains(log.text(), "the auth API is down") {
		t.Fatalf("log:\n%s", log.text())
	}
	if !strings.Contains(log.text(), "not authorized") {
		// The tenth failure in a row logs it.
		t.Fatalf("refusal not logged:\n%s", log.text())
	}
}

func TestRefusedSubscriptionStillPublishes(t *testing.T) {
	f := newFakeIoT(t)
	f.broker.RefuseTopics["presence/prod/"+identity+"/requests"] = true
	l, log, _ := start(t, f, nil)
	s := f.session(t)
	<-s.Subscribed
	l.PublishEvent([]byte(`{"id":"e1","time":5}`), "k", "")
	if m := published(t, s); !strings.HasSuffix(m.Topic, "/events") {
		t.Fatalf("on %s", m.Topic)
	}
	if !strings.Contains(log.text(), "could not subscribe to requests") {
		t.Fatalf("log:\n%s", log.text())
	}
}

// Live sync never holds up the recording: with no connection, events
// queue up to the limit and the rest are dropped, at once.
func TestPublishNeverBlocks(t *testing.T) {
	log := &logs{}
	l, err := New(Config{Endpoint: "127.0.0.1:1", Stage: "rc", IdentityID: identity, DeviceID: "brave_quiet_fox",
		Credentials: noCredentials, Logf: log.logf})
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	queued := 0
	for i := 0; i < maxOutbox+50; i++ {
		if l.PublishEvent([]byte(`{"id":"e","time":1}`), "k", "") {
			queued++
		}
	}
	if queued != maxOutbox || time.Since(start) > time.Second {
		t.Fatalf("queued %d in %s", queued, time.Since(start))
	}
	if !strings.Contains(log.text(), "the queue is full") {
		t.Fatalf("log:\n%s", log.text())
	}
}

func TestRedact(t *testing.T) {
	err := errors.New(`dial wss://h/mqtt?X-Amz-Security-Token=abc&X-Amz-Signature=def: refused`)
	if got := redact(err); got != "dial wss://h/mqtt?… refused" {
		t.Fatal(got)
	}
}
