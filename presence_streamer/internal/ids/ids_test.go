package ids

import (
	"os"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestWordsMatchTheApp(t *testing.T) {
	src, err := os.ReadFile("../../../presence_app/lib/identity/device_words.dart")
	if os.IsNotExist(err) {
		t.Skip("the app isn't checked out next to the streamer")
	}
	if err != nil {
		t.Fatal(err)
	}
	words := func(name string) []string {
		m := regexp.MustCompile(`(?s)` + name + ` = '''(.*?)'''`).FindSubmatch(src)
		if m == nil {
			t.Fatalf("no %s in device_words.dart", name)
		}
		return strings.Fields(string(m[1]))
	}
	if got, want := strings.Join(adjectives, " "), strings.Join(words("adjectiveWords"), " "); got != want {
		t.Error("adjectives differ from the app's: regenerate words.go")
	}
	if got, want := strings.Join(things, " "), strings.Join(words("thingWords"), " "); got != want {
		t.Error("things differ from the app's: regenerate words.go")
	}
}

func TestNewDevice(t *testing.T) {
	for range 1000 {
		id := NewDevice()
		parts := strings.Split(id, "_")
		if !DevicePattern.MatchString(id) || len(id) > 64 || parts[0] == parts[1] {
			t.Fatalf("bad device ID %q", id)
		}
	}
}

func TestNewEvent(t *testing.T) {
	at := time.UnixMicro(1790436872000000)
	id := NewEvent(at)
	if !regexp.MustCompile(`^[0-9a-z]+-[0-9a-z]{7}$`).MatchString(id) {
		t.Fatalf("bad event ID %q", id)
	}
	if !strings.HasPrefix(id, "hmnncdvmrk-") {
		t.Fatalf("event ID %q doesn't start with the time in base 36", id)
	}
	if NewEvent(at) == id {
		t.Fatal("two IDs at the same time are equal")
	}
	if a, b := NewEvent(at), NewEvent(at.Add(time.Second)); a >= b {
		t.Fatalf("IDs aren't time-ordered: %q, %q", a, b)
	}
}
