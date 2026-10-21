// Package livesync connects the streamer to the profile's live sync, as the
// app's LiveSync (presence_app/lib/cloud/live_sync.dart; specs/live-sync.md)
// does for a device that is always connected: MQTT 3.1.1 over a WebSocket
// to AWS IoT Core, presigned with the profile's Cognito credentials. It
// publishes each event the streamer stores, so the profile's devices show
// it within a second, and answers device presence's pings, so the streamer
// shows live. It never holds up the recording: events wait in a bounded
// queue, and live sync failing leaves the bucket to carry them, as before.
//
// It subscribes to the requests topic alone: the streamer takes no other
// device's events (nor their `copied` acks), and answers only pings
// (another device's Sync request is ignored).
package livesync

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"sync/atomic"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/mqtt"
	"github.com/prodbytes/presence/presence_streamer/internal/sigv4"
	"github.com/prodbytes/presence/presence_streamer/internal/ws"
)

// Timings, as the app's.
const (
	// pingFresh: a ping older than this (by its sentAt) isn't answered.
	pingFresh = 2 * time.Minute
	// answerEvery: at most one pong per this (pings from several devices
	// at once get one answer, heard by all).
	answerEvery = 5 * time.Second
	// maxOutbox: at most this many events wait to be sent; more are
	// dropped (the bucket carries them).
	maxOutbox = 100
	// presignFor is how long a signed URL is good for.
	presignFor = time.Hour
)

// Config is what Live connects as, and where.
type Config struct {
	// Endpoint is the AWS IoT data endpoint
	// (`<id>-ats.iot.<region>.amazonaws.com`), or the local stack's
	// broker, `ws://localhost:4566`.
	Endpoint string
	// Region signs the URL; empty is the endpoint's (or IdentityID's).
	Region string
	// Stage is the topics' second level: prod or rc.
	Stage string
	// IdentityID is the profile's Cognito identity, DeviceID this
	// streamer's.
	IdentityID, DeviceID string
	// MediaKey is the device's media key, base64, sent with each event so
	// devices without the bucket's settings open its sealed media.
	MediaKey string
	// Credentials are the identity's AWS credentials (fresh ones each
	// time they're asked for, near their expiry).
	Credentials func(context.Context) (sigv4.Credentials, error)
	Logf        func(string, ...any)

	// Tests: the WebSocket's TLS configuration (nil verifies against the
	// system's roots), the clock, and the timings (0: the app's).
	TLS            *tls.Config
	Now            func() time.Time
	MinRetry       time.Duration // 1 s, doubling after each failure...
	MaxRetry       time.Duration // ...up to 2 min
	RenewBefore    time.Duration // 2 min before the credentials expire
	ConnectTimeout time.Duration // 15 s for credentials, and to connect
	KeepAlive      time.Duration // 60 s
}

var (
	awsEndpoint   = regexp.MustCompile(`^[a-z0-9]+-ats\.iot\.([a-z0-9-]+)\.amazonaws\.com$`)
	hostPort      = regexp.MustCompile(`^[A-Za-z0-9.-]+(:[0-9]{1,5})?$`)
	localEndpoint = regexp.MustCompile(`^ws://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?$`)
	identityID    = regexp.MustCompile(`^[a-z]{2}(-[a-z]+)+-[0-9]:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

// Live is the streamer's live sync.
type Live struct {
	cfg     Config
	scheme  string
	host    string
	session string
	outbox  chan []byte

	connected atomic.Bool
	sent      atomic.Int64
	pongs     atomic.Int64
	dropped   atomic.Int64

	// lastPong is when the last pong went (Run's goroutine only).
	lastPong time.Time
	// malformed counts the messages dropped, for the log.
	malformed int
}

// New checks cfg and makes a Live; Run connects it.
func New(cfg Config) (*Live, error) {
	l := &Live{cfg: cfg, outbox: make(chan []byte, maxOutbox)}
	switch {
	case localEndpoint.MatchString(cfg.Endpoint):
		l.scheme, l.host = "ws", strings.TrimPrefix(cfg.Endpoint, "ws://")
	case hostPort.MatchString(cfg.Endpoint):
		l.scheme, l.host = "wss", cfg.Endpoint
	default:
		return nil, fmt.Errorf("live sync: %q isn't an AWS IoT endpoint", cfg.Endpoint)
	}
	if cfg.Stage != "prod" && cfg.Stage != "rc" {
		return nil, fmt.Errorf("live sync: stage %q: prod or rc", cfg.Stage)
	}
	if !identityID.MatchString(cfg.IdentityID) || !SafeID(cfg.DeviceID) || len(cfg.MediaKey) > 64 {
		return nil, errors.New("live sync: a bad identity, device ID or media key")
	}
	if cfg.Credentials == nil {
		return nil, errors.New("live sync: no credentials")
	}
	if l.cfg.Region == "" {
		l.cfg.Region = RegionOf(cfg.Endpoint, cfg.IdentityID)
	}
	if l.cfg.Logf == nil {
		l.cfg.Logf = func(string, ...any) {}
	}
	if l.cfg.Now == nil {
		l.cfg.Now = time.Now
	}
	l.cfg.MinRetry = or(l.cfg.MinRetry, time.Second)
	l.cfg.MaxRetry = or(l.cfg.MaxRetry, 2*time.Minute)
	l.cfg.RenewBefore = or(l.cfg.RenewBefore, 2*time.Minute)
	l.cfg.ConnectTimeout = or(l.cfg.ConnectTimeout, 15*time.Second)
	l.cfg.KeepAlive = or(l.cfg.KeepAlive, 60*time.Second)
	l.session = randomID(6)
	return l, nil
}

func or(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

// RegionOf is the region an endpoint is in (`…-ats.iot.<region>.…`), else
// the identity's (`<region>:<uuid>`).
func RegionOf(endpoint, identityID string) string {
	if m := awsEndpoint.FindStringSubmatch(endpoint); m != nil {
		return m[1]
	}
	region, _, _ := strings.Cut(identityID, ":")
	return region
}

// randomID is n random lowercase letters and digits.
func randomID(n int) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i := range b {
		k, err := rand.Int(rand.Reader, big.NewInt(int64(len(alphabet))))
		if err != nil {
			panic(err)
		}
		b[i] = alphabet[k.Int64()]
	}
	return string(b)
}

// ClientID is the connection's MQTT client ID:
// `<identityId>-<deviceId>-<session>`, as the app's when always connected.
// The IoT policy allows only IDs that start with the identity.
func (l *Live) ClientID() string {
	return l.cfg.IdentityID + "-" + l.cfg.DeviceID + "-" + l.session
}

// Connected says whether it's connected now.
func (l *Live) Connected() bool { return l.connected.Load() }

// Sent is how many events went to the broker (handed to the connection at
// QoS 1; the broker's PUBACK isn't waited for).
func (l *Live) Sent() int64 { return l.sent.Load() }

// Pongs is how many pings it answered.
func (l *Live) Pongs() int64 { return l.pongs.Load() }

// PublishEvent queues the event (its JSON as uploaded to the bucket, at
// key, with the upload's ETag: its MD5, hex) for the profile's other
// devices. It never blocks: false when the event isn't one, its message
// would pass [MaxMessage], or the queue is full (the bucket carries it).
func (l *Live) PublishEvent(event []byte, key, etag string) bool {
	var record map[string]json.RawMessage
	if json.Unmarshal(event, &record) != nil || record == nil || (etag != "" && !etagPattern.MatchString(etag)) {
		return false
	}
	payload, err := json.Marshal(eventMessage{
		V: Version, Kind: "event", DeviceID: l.cfg.DeviceID, IdentityID: l.cfg.IdentityID,
		SentAt: l.cfg.Now().UnixMilli(), Key: key, ETag: etag, MediaKey: l.cfg.MediaKey,
		Event: json.RawMessage(event),
	})
	if err != nil || len(payload) > MaxMessage {
		l.cfg.Logf("live sync: not sending an event of %d bytes", len(event))
		return false
	}
	select {
	case l.outbox <- payload:
		return true
	default:
		if n := l.dropped.Add(1); n == 1 || n%100 == 0 {
			l.cfg.Logf("live sync: %d events not sent (the queue is full); the bucket has them", n)
		}
		return false
	}
}

// redact is err as text, without any URL's query: a presigned URL's holds
// the session token (the app's LiveSync.redact).
var query = regexp.MustCompile(`\?[^\s'"]*`)

func redact(err error) string {
	return query.ReplaceAllString(err.Error(), "?…")
}

// Run connects, and connects again after each drop or failure (with a
// back-off) and before the credentials expire, until ctx ends.
func (l *Live) Run(ctx context.Context) {
	failures := 0
	for ctx.Err() == nil {
		up, renew, err := l.connectOnce(ctx)
		l.connected.Store(false)
		if ctx.Err() != nil {
			return
		}
		switch {
		case renew:
			// New credentials, and a newly signed URL, at once.
			failures = 0
			continue
		case up:
			// Dropped: again soon.
			l.cfg.Logf("live sync disconnected (%s); reconnecting", redact(err))
			failures = 1
		default:
			failures++
			wait := l.retryDelay(failures)
			if failures == 1 || failures%10 == 0 {
				l.cfg.Logf("live sync failed (%d in a row, next try in %s): %s", failures, wait, redact(err))
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(l.retryDelay(failures)):
		}
	}
}

// retryDelay is MinRetry, doubling with each failure in a row, up to
// MaxRetry.
func (l *Live) retryDelay(failures int) time.Duration {
	d := l.cfg.MinRetry
	for i := 1; i < failures && d < l.cfg.MaxRetry; i++ {
		d *= 2
	}
	return min(d, l.cfg.MaxRetry)
}

// errRenew ends a connection to renew it.
var errRenew = errors.New("renewing")

// connectOnce connects with fresh credentials and stays until the
// connection drops, ctx ends, or the credentials are about to expire. up:
// it was connected; renew: it ended to renew.
func (l *Live) connectOnce(ctx context.Context) (up, renew bool, err error) {
	cctx, cancel := context.WithTimeout(ctx, l.cfg.ConnectTimeout)
	creds, err := l.cfg.Credentials(cctx)
	cancel()
	if err != nil {
		return false, false, fmt.Errorf("credentials: %w", err)
	}
	url := sigv4.PresignWebSocket(l.scheme, l.host, "/mqtt", l.cfg.Region, "iotdevicegateway", creds, l.cfg.Now(), presignFor)
	cctx, cancel = context.WithTimeout(ctx, l.cfg.ConnectTimeout)
	defer cancel()
	conn, err := ws.Dial(cctx, url, ws.Options{Subprotocol: "mqtt", TLS: l.cfg.TLS})
	if err != nil {
		return false, false, err
	}
	client, err := mqtt.Connect(cctx, conn, mqtt.Options{ClientID: l.ClientID(), Clean: true, KeepAlive: l.cfg.KeepAlive})
	if err != nil {
		return false, false, err
	}
	defer client.Close()
	requests := TopicOf(l.cfg.Stage, l.cfg.IdentityID, Requests)
	if _, err := client.Subscribe(cctx, requests, 1); err != nil {
		if !errors.Is(err, mqtt.ErrSubscriptionRefused) {
			return false, false, err
		}
		// Events still go; presence just isn't answered.
		l.cfg.Logf("live sync could not subscribe to requests: %v", err)
	}
	cancel()
	l.connected.Store(true)
	l.cfg.Logf("live sync connected (%s)", l.cfg.Stage)

	// New credentials (and a newly signed URL) before these expire; not
	// when they're about to already, which would only loop.
	var renewAt <-chan time.Time
	if !creds.Expiration.IsZero() {
		if left := creds.Expiration.Sub(l.cfg.Now()) - l.cfg.RenewBefore; left > 0 {
			t := time.NewTimer(left)
			defer t.Stop()
			renewAt = t.C
		}
	}
	events := TopicOf(l.cfg.Stage, l.cfg.IdentityID, Events)
	for {
		select {
		case <-ctx.Done():
			return true, false, ctx.Err()
		case <-client.Done():
			return true, false, client.Err()
		case <-renewAt:
			return true, true, errRenew
		case m := <-client.Messages():
			if m.Topic == requests {
				l.onRequest(client, m.Payload)
			}
		case payload := <-l.outbox:
			if err := client.Publish(events, payload, 1, false); err != nil {
				// Lost with the connection: the bucket has it.
				return true, false, err
			}
			l.sent.Add(1)
		}
	}
}

// onRequest answers another device's ping with a pong on acks, as the
// app's LiveSync._onPresence: not its own, not one older than pingFresh,
// at most one pong per answerEvery.
func (l *Live) onRequest(client *mqtt.Client, payload []byte) {
	ping, err := parsePing(payload, l.cfg.IdentityID)
	if errors.Is(err, errNotPing) {
		return
	}
	if err != nil {
		l.malformed++
		if l.malformed == 1 || l.malformed%100 == 0 {
			l.cfg.Logf("live sync dropped a malformed presence message (%d bytes: %v; %d so far)", len(payload), err, l.malformed)
		}
		return
	}
	if ping.DeviceID == l.cfg.DeviceID {
		return
	}
	now := l.cfg.Now()
	if now.Sub(time.UnixMilli(ping.SentAt)) > pingFresh {
		return
	}
	if !l.lastPong.IsZero() && !now.Before(l.lastPong) && now.Sub(l.lastPong) < answerEvery {
		return
	}
	l.lastPong = now
	pong, _ := json.Marshal(presenceMessage{
		V: Version, Kind: "pong", DeviceID: l.cfg.DeviceID, IdentityID: l.cfg.IdentityID,
		SentAt: now.UnixMilli(), Nonce: ping.Nonce,
	})
	if err := client.Publish(TopicOf(l.cfg.Stage, l.cfg.IdentityID, Acks), pong, 1, false); err != nil {
		l.cfg.Logf("live sync could not answer a ping: %s", redact(err))
		return
	}
	l.pongs.Add(1)
}
