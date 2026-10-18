package sigv4

import (
	"strings"
	"testing"
	"time"
)

// The app's own vector (presence_app/test/live_sync_test.dart, checked there
// against an independent Python implementation): both sign alike.
func TestPresignWebSocketMatchesTheApp(t *testing.T) {
	got := PresignWebSocket("wss", "abc123-ats.iot.us-east-1.amazonaws.com", "/mqtt", "us-east-1", "iotdevicegateway",
		Credentials{AccessKeyID: "AKIDEXAMPLE", SecretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", SessionToken: "session/token+="},
		time.Date(2026, 10, 6, 12, 34, 56, 0, time.UTC), time.Hour)
	want := "wss://abc123-ats.iot.us-east-1.amazonaws.com/mqtt" +
		"?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
		"&X-Amz-Credential=AKIDEXAMPLE%2F20261006%2Fus-east-1%2F" +
		"iotdevicegateway%2Faws4_request" +
		"&X-Amz-Date=20261006T123456Z" +
		"&X-Amz-Expires=3600" +
		"&X-Amz-SignedHeaders=host" +
		"&X-Amz-Signature=" +
		"6b4979fbf8f64c22fa244292a972bf18532ea2ab3d7ca07d30b75d7e30da0134" +
		"&X-Amz-Security-Token=session%2Ftoken%2B%3D"
	if got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
}

func TestPresignWithoutTokenAndInAnotherZone(t *testing.T) {
	creds := Credentials{AccessKeyID: "AKIDEXAMPLE", SecretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"}
	utc := PresignWebSocket("wss", "h", "/mqtt", "us-east-1", "iotdevicegateway", creds, time.Date(2026, 10, 6, 12, 34, 56, 0, time.UTC), time.Hour)
	if strings.Contains(utc, "Security-Token") {
		t.Fatalf("a token without one: %s", utc)
	}
	// The same instant in another zone signs the same.
	zone := time.FixedZone("x", -3*3600)
	other := PresignWebSocket("wss", "h", "/mqtt", "us-east-1", "iotdevicegateway", creds, time.Date(2026, 10, 6, 9, 34, 56, 0, zone), time.Hour)
	if utc != other {
		t.Fatalf("zones differ:\n%s\n%s", utc, other)
	}
}

func TestURIEncode(t *testing.T) {
	for in, want := range map[string]string{
		"aZ09-_.~": "aZ09-_.~",
		"a/b+c=":   "a%2Fb%2Bc%3D",
		" ":        "%20",
		"é":        "%C3%A9",
	} {
		if got := uriEncode(in); got != want {
			t.Errorf("uriEncode(%q) = %q, want %q", in, got, want)
		}
	}
	if canonicalPath("") != "/" || canonicalPath("/mqtt") != "/mqtt" {
		t.Error("canonicalPath")
	}
}
