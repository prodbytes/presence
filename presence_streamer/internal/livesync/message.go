package livesync

import (
	"bytes"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
)

// Version is the messages' format version (`v`), the app's
// LiveSync.version.
const Version = 1

// MaxMessage is the largest message sent: the app's
// LiveSync.maxMessageBytes (AWS IoT allows 128 KB).
const MaxMessage = 64 << 10

// MaxPresence is the largest presence message (ping) taken: the app's
// LiveSync.maxPresenceBytes.
const MaxPresence = 1024

// The topics' kinds.
const (
	Events   = "events"
	Requests = "requests"
	Acks     = "acks"
)

// TopicOf is the profile's topic of kind: `presence/<stage>/<identity>/<kind>`.
func TopicOf(stage, identityID, kind string) string {
	return "presence/" + stage + "/" + identityID + "/" + kind
}

var (
	idPattern    = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
	noncePattern = regexp.MustCompile(`^[A-Za-z0-9]{8,64}$`)
	etagPattern  = regexp.MustCompile(`^[0-9a-f]{32}$`)
)

// SafeID says whether id is safe as an event, clip or device ID (it goes
// into object keys): the app's Records.isSafeId.
func SafeID(id string) bool {
	return idPattern.MatchString(id) && !strings.Contains(id, "..")
}

// eventMessage is an event for the profile's other devices, as the app's
// LiveSync.publishEvent sends it: no `clip` (a premium profile's devices
// take clips from the bucket, and a streamer's profile is premium).
type eventMessage struct {
	V          int             `json:"v"`
	Kind       string          `json:"kind"`
	DeviceID   string          `json:"deviceId"`
	IdentityID string          `json:"identityId"`
	SentAt     int64           `json:"sentAt"`
	Key        string          `json:"key"`
	ETag       string          `json:"etag,omitempty"`
	MediaKey   string          `json:"mediaKey,omitempty"`
	Event      json.RawMessage `json:"event"`
}

// presenceMessage is a ping or a pong: `{"v":1,"kind":…,"deviceId",
// "identityId","sentAt","nonce"}`.
type presenceMessage struct {
	V          int    `json:"v"`
	Kind       string `json:"kind"`
	DeviceID   string `json:"deviceId"`
	IdentityID string `json:"identityId"`
	SentAt     int64  `json:"sentAt"`
	Nonce      string `json:"nonce,omitempty"`
}

// errNotPing is a valid message on requests that isn't a ping (another
// device's Sync button, `sync`): not answered, not an error.
var errNotPing = errors.New("not a ping")

// parsePing is the ping in payload, a message on identityID's requests
// topic, as the app's LiveSync.parsePresence checks it: at most 1 KB, a
// JSON object of version 1, kind ping, for identityID, from a safe device
// ID, with an integer sentAt and a nonce of 8 to 64 letters and digits.
// A `sync` request is errNotPing.
func parsePing(payload []byte, identityID string) (presenceMessage, error) {
	var none presenceMessage
	if len(payload) > MaxPresence {
		return none, errors.New("over 1 KB")
	}
	var fields map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(payload))
	if err := dec.Decode(&fields); err != nil || fields == nil || dec.More() {
		return none, errors.New("not a JSON object")
	}
	var m presenceMessage
	if !intField(fields, "v", func(v int64) { m.V = int(v) }) || m.V != Version {
		return none, errors.New("another version")
	}
	if !stringField(fields, "kind", &m.Kind) {
		return none, errors.New("no kind")
	}
	if !stringField(fields, "identityId", &m.IdentityID) || m.IdentityID != identityID {
		return none, errors.New("another identity")
	}
	if !stringField(fields, "deviceId", &m.DeviceID) || !SafeID(m.DeviceID) {
		return none, errors.New("an unsafe device ID")
	}
	if m.Kind == "sync" {
		return none, errNotPing
	}
	if m.Kind != "ping" {
		return none, errors.New("not a ping")
	}
	if !intField(fields, "sentAt", func(v int64) { m.SentAt = v }) {
		return none, errors.New("no integer sentAt")
	}
	if !stringField(fields, "nonce", &m.Nonce) || !noncePattern.MatchString(m.Nonce) {
		return none, errors.New("a bad nonce")
	}
	return m, nil
}

// stringField sets *to to fields[name], when it's a string.
func stringField(fields map[string]json.RawMessage, name string, to *string) bool {
	raw, ok := fields[name]
	return ok && json.Unmarshal(raw, to) == nil && len(raw) > 0 && raw[0] == '"'
}

// intField calls set with fields[name], when it's an integer (not 1.5, not
// "1").
func intField(fields map[string]json.RawMessage, name string, set func(int64)) bool {
	raw, ok := fields[name]
	if !ok {
		return false
	}
	var n json.Number
	if json.Unmarshal(raw, &n) != nil || len(raw) == 0 || raw[0] == '"' {
		return false
	}
	v, err := n.Int64()
	if err != nil {
		return false
	}
	set(v)
	return true
}
