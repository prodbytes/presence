// Package ids makes the IDs the app makes: device IDs
// (`automatic_paranoid_gadget`, as presence_app/lib/identity/device_id.dart)
// and event and clip IDs (as AppEvent.newId in presence_app/lib/events.dart).
package ids

import (
	"crypto/rand"
	"encoding/binary"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	adjectives = strings.Fields(adjectiveWords)
	things     = strings.Fields(thingWords)
)

// DevicePattern is what a device ID looks like (the auth API refuses
// others).
var DevicePattern = regexp.MustCompile(`^[a-z]+_[a-z]+_[a-z]+$`)

// ProfilePattern is what a profile ID looks like
// (`automatic_paranoid_axolotl`).
var ProfilePattern = DevicePattern

func pick(n int) int {
	i, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		panic(err)
	}
	return int(i.Int64())
}

// NewDevice is a new random device ID: two different adjectives and a thing.
func NewDevice() string {
	first := pick(len(adjectives))
	second := pick(len(adjectives) - 1)
	if second >= first {
		second++
	}
	return adjectives[first] + "_" + adjectives[second] + "_" + things[pick(len(things))]
}

// NewEvent is a new event or clip ID: the time in microseconds and 32
// random bits, both in base 36 (`mgk3v1q8h0-0f3kq1z`), time-ordered.
func NewEvent(now time.Time) string {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	noise := strconv.FormatUint(uint64(binary.BigEndian.Uint32(b[:])), 36)
	return strconv.FormatInt(now.UnixMicro(), 36) + "-" + strings.Repeat("0", max(0, 7-len(noise))) + noise
}
