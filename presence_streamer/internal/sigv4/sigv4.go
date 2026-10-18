// Package sigv4 presigns a WebSocket URL with AWS Signature Version 4, as
// the app's SigV4Signer.presignWebSocket does (presence_app/lib/cloud/
// sigv4.dart): live sync's connection to AWS IoT Core (service
// `iotdevicegateway`), with only `host` signed and the session token
// appended after signing, as AWS IoT requires.
package sigv4

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Credentials are temporary AWS credentials: the profile's Cognito
// identity's.
type Credentials struct {
	AccessKeyID, SecretKey, SessionToken string
	// Expiration is when they stop working (zero: unknown).
	Expiration time.Time
}

// emptyPayloadHash is SHA-256 of nothing: a GET's payload.
const emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

// PresignWebSocket is scheme://host+path signed for region and service at
// now, valid for expires: a query with the signature, then the session
// token (when there is one).
func PresignWebSocket(scheme, host, path, region, service string, creds Credentials, now time.Time, expires time.Duration) string {
	amzDate := now.UTC().Format("20060102T150405Z")
	date := amzDate[:8]
	scope := date + "/" + region + "/" + service + "/aws4_request"
	query := canonicalQuery(map[string]string{
		"X-Amz-Algorithm":     "AWS4-HMAC-SHA256",
		"X-Amz-Credential":    creds.AccessKeyID + "/" + scope,
		"X-Amz-Date":          amzDate,
		"X-Amz-Expires":       fmt.Sprint(int64(expires / time.Second)),
		"X-Amz-SignedHeaders": "host",
	})
	canonicalRequest := strings.Join([]string{
		"GET",
		canonicalPath(path),
		query,
		"host:" + host,
		"",
		"host",
		emptyPayloadHash,
	}, "\n")
	hash := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := strings.Join([]string{"AWS4-HMAC-SHA256", amzDate, scope, hex.EncodeToString(hash[:])}, "\n")
	key := mac([]byte("AWS4"+creds.SecretKey), date)
	key = mac(key, region)
	key = mac(key, service)
	key = mac(key, "aws4_request")
	signature := hex.EncodeToString(mac(key, stringToSign))
	url := scheme + "://" + host + path + "?" + query + "&X-Amz-Signature=" + signature
	if creds.SessionToken != "" {
		url += "&X-Amz-Security-Token=" + uriEncode(creds.SessionToken)
	}
	return url
}

func mac(key []byte, data string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(data))
	return h.Sum(nil)
}

// canonicalPath is path with each segment URI-encoded once ("/" when
// empty).
func canonicalPath(path string) string {
	if path == "" {
		return "/"
	}
	segments := strings.Split(path, "/")
	for i, s := range segments {
		segments[i] = uriEncode(s)
	}
	return strings.Join(segments, "/")
}

// canonicalQuery is the parameters encoded, sorted, joined with "&".
func canonicalQuery(params map[string]string) string {
	pairs := make([]string, 0, len(params))
	for k, v := range params {
		pairs = append(pairs, uriEncode(k)+"="+uriEncode(v))
	}
	sort.Strings(pairs)
	return strings.Join(pairs, "&")
}

// uriEncode is RFC 3986 encoding, as AWS requires: everything but A-Z a-z
// 0-9 - _ . ~ as %XX (upper case).
func uriEncode(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
