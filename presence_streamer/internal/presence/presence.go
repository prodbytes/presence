// Package presence asks the auth API who the signed-in account is and for
// its profile's credentials, as the app does (see specs/auth-api.md and
// specs/cloud-sync.md), and trades them with Cognito for AWS credentials.
// A Google sign-in's ID token is first exchanged for a Presence session
// token (POST /api/auth/session), which the other calls carry.
package presence

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// API is the auth API of a Presence site (https://presence.nu01.com).
// Signed in with Google, it calls the API with the Presence session token
// it exchanges the Google ID token for (the APIs take no Google tokens).
type API struct {
	BaseURL string
	HTTP    *http.Client
	// CognitoURL overrides Cognito's endpoint (tests); empty is AWS's for
	// the identity's region.
	CognitoURL string

	// mu guards session: the session token last exchanged.
	mu      sync.Mutex
	session *sessionToken
}

// sessionToken is a Presence session token and the Google ID token it was
// exchanged for.
type sessionToken struct {
	idToken, token string
	expires        time.Time
}

// ErrUnauthorized is the auth API refusing the Google ID token (expired, or
// not for its client).
var ErrUnauthorized = errors.New("the auth API refused the Google sign-in")

// ErrKeyRefused is the auth API refusing the stream key: not this device's
// (a newer one replaced it, or the device was deleted in the app).
var ErrKeyRefused = errors.New("the auth API refused the stream key: copy a new command from the app's profile view")

// Leader is a profile's leading streamer: the one of its streamers that
// streams, and when the auth API last heard from it.
type Leader struct {
	Device string `json:"device"`
	SeenAt int64  `json:"seenAt"`
}

// NotLeaderError is the auth API refusing a streamer credentials (409,
// "notLeader") because another streamer leads the profile.
type NotLeaderError struct{ Leader *Leader }

func (e NotLeaderError) Error() string {
	if e.Leader == nil {
		return "another streamer leads this profile"
	}
	return fmt.Sprintf("another streamer, %s, leads this profile", e.Leader.Device)
}

// Lease is the auth API's answer to a streamer's lease (POST
// /api/auth/stream/lease): whether it leads the profile, the leader, and
// how long a leader may be silent before another takes its place.
type Lease struct {
	Leader       bool    `json:"leader"`
	StreamLeader *Leader `json:"streamLeader"`
	SilenceMs    int64   `json:"silenceMs"`
}

var (
	identityPattern = regexp.MustCompile(`^[a-z]{2}(-[a-z]+)+-[0-9]:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	bucketPattern   = regexp.MustCompile(`^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$`)
)

// ValidBucket says whether name is an S3 bucket name (it goes into rclone's
// paths).
func ValidBucket(name string) bool {
	return bucketPattern.MatchString(name) && !strings.Contains(name, "..")
}

// Credentials are the auth API's answer to POST /api/auth/credentials.
type Credentials struct {
	IdentityID  string   `json:"identityId"`
	Token       string   `json:"token"`
	Tier        string   `json:"tier"`
	DeviceLimit int      `json:"deviceLimit"`
	Devices     []string `json:"devices"`
	// Bucket is the user-data bucket (newer auth APIs only).
	Bucket string `json:"bucket"`
	// UserID is the Google ID of who made the stream key (stream
	// credentials only): the events' userId.
	UserID string `json:"userId"`
	// Local are AWS credentials the auth API gives itself, in Cognito's
	// shape: the local stack's (Floci has no Cognito Identity).
	Local *cognitoCredentials `json:"credentials"`
}

// cognitoCredentials are AWS credentials as Cognito answers them.
type cognitoCredentials struct {
	AccessKeyID  string  `json:"AccessKeyId"`
	SecretKey    string  `json:"SecretKey"`
	SessionToken string  `json:"SessionToken"`
	Expiration   float64 `json:"Expiration"`
}

// Premium is whether the profile is premium (it may use the bucket).
func (c Credentials) Premium() bool { return c.Tier == "premium" }

// AWS are temporary AWS credentials for the profile's folder.
type AWS struct {
	AccessKeyID, SecretKey, SessionToken string
	Expiration                           time.Time
}

func (a *API) http() *http.Client {
	if a.HTTP != nil {
		return a.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

// call calls the auth API as the Google sign-in idToken: with the Presence
// session token it exchanges idToken for.
func (a *API) call(ctx context.Context, method, path, idToken string, body io.Reader, out any) error {
	token, err := a.sessionToken(ctx, idToken)
	if err != nil {
		return err
	}
	return a.callAs(ctx, method, path, token, ErrUnauthorized, body, out)
}

// sessionToken is the Presence session token for the Google ID token
// idToken: the one exchanged before, until a minute before it expires, or a
// new one (POST /api/auth/session). It asks for no refresh token: the
// streamer keeps Google's refresh token and exchanges each new ID token.
func (a *API) sessionToken(ctx context.Context, idToken string) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if s := a.session; s != nil && s.idToken == idToken && time.Now().Before(s.expires.Add(-time.Minute)) {
		return s.token, nil
	}
	body, err := json.Marshal(map[string]any{"provider": "google", "idToken": idToken, "refresh": false})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(a.BaseURL, "/")+"/api/auth/session", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	var answer struct {
		Token     string `json:"token"`
		ExpiresAt int64  `json:"expiresAt"`
	}
	if err := a.do(req, ErrUnauthorized, &answer); err != nil {
		return "", err
	}
	if answer.Token == "" {
		return "", errors.New("the auth API answered no session token")
	}
	a.session = &sessionToken{idToken: idToken, token: answer.Token, expires: time.Unix(answer.ExpiresAt, 0)}
	return answer.Token, nil
}

// callAs calls the auth API with bearer as the Authorization; a 401 is
// refused.
func (a *API) callAs(ctx context.Context, method, path, bearer string, refused error, body io.Reader, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(a.BaseURL, "/")+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+bearer)
	if body != nil {
		req.Header.Set("Content-Type", "text/plain")
	}
	return a.do(req, refused, out)
}

// do sends req to the auth API and reads its answer into out; a 401 is
// refused.
func (a *API) do(req *http.Request, refused error, out any) error {
	res, err := a.http().Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return err
	}
	switch {
	case res.StatusCode == http.StatusUnauthorized:
		return refused
	case res.StatusCode != http.StatusOK:
		var e struct {
			Error        string  `json:"error"`
			Reason       string  `json:"reason"`
			StreamLeader *Leader `json:"streamLeader"`
		}
		_ = json.Unmarshal(data, &e)
		if res.StatusCode == http.StatusConflict && e.Reason == "notLeader" {
			return NotLeaderError{Leader: e.StreamLeader}
		}
		return fmt.Errorf("%s %s: HTTP %d %s", req.Method, req.URL.Path, res.StatusCode, e.Error)
	}
	return json.Unmarshal(data, out)
}

// Profile is the profile ID of the account signed in with the Google ID
// token idToken (GET /api/auth/profile, with its session token).
func (a *API) Profile(ctx context.Context, idToken string) (string, error) {
	var answer struct {
		Profile string `json:"profile"`
	}
	if err := a.call(ctx, http.MethodGet, "/api/auth/profile", idToken, nil, &answer); err != nil {
		return "", err
	}
	if answer.Profile == "" {
		return "", errors.New("the auth API answered no profile")
	}
	return answer.Profile, nil
}

// Credentials are the profile's credentials, for the device deviceID
// (which the auth API adds to the profile's devices).
func (a *API) Credentials(ctx context.Context, idToken, deviceID string) (Credentials, error) {
	var c Credentials
	err := a.call(ctx, http.MethodPost, "/api/auth/credentials", idToken, strings.NewReader(deviceID), &c)
	return c, checked(c, err)
}

// StreamCredentials are the profile's credentials for its device deviceID,
// with the device's stream key (from the app's profile view) instead of a
// Google sign-in (POST /api/auth/stream/credentials). cameras are the
// devices it streams for (its Blink cameras), which join the profile's
// devices too.
func (a *API) StreamCredentials(ctx context.Context, key, profileID, deviceID string, cameras ...string) (Credentials, error) {
	var c Credentials
	body := strings.Join(append([]string{profileID, deviceID}, cameras...), " ")
	err := a.callAs(ctx, http.MethodPost, "/api/auth/stream/credentials", key, ErrKeyRefused,
		strings.NewReader(body), &c)
	return c, checked(c, err)
}

// StreamLease renews or asks for the leadership of the device deviceID,
// with its stream key (POST /api/auth/stream/lease).
func (a *API) StreamLease(ctx context.Context, key, profileID, deviceID string) (Lease, error) {
	var l Lease
	err := a.callAs(ctx, http.MethodPost, "/api/auth/stream/lease", key, ErrKeyRefused,
		strings.NewReader(profileID+" "+deviceID), &l)
	return l, err
}

// ProfileLease is StreamLease for a streamer signed in with Google (POST
// /api/auth/profile/stream-lease, with its session token).
func (a *API) ProfileLease(ctx context.Context, idToken, deviceID string) (Lease, error) {
	var l Lease
	err := a.call(ctx, http.MethodPost, "/api/auth/profile/stream-lease", idToken, strings.NewReader(deviceID), &l)
	return l, err
}

// checked is err, or what's wrong with the answer c.
func checked(c Credentials, err error) error {
	switch {
	case err != nil:
	case c.IdentityID == "" || c.Token == "":
		err = errors.New("the auth API answered no identity or token")
	case !identityPattern.MatchString(c.IdentityID):
		// It names Cognito's host and the folder in the bucket.
		err = fmt.Errorf("the auth API answered an identity ID that isn't one: %q", c.IdentityID)
	case c.Bucket != "" && !ValidBucket(c.Bucket):
		err = fmt.Errorf("the auth API answered a bucket name that isn't one: %q", c.Bucket)
	}
	return err
}

// AWSCredentials trades the auth API's token with Cognito
// (GetCredentialsForIdentity, unsigned: the token is the proof).
func (a *API) AWSCredentials(ctx context.Context, c Credentials) (AWS, error) {
	if c.Local != nil {
		return awsOf(*c.Local, "the auth API")
	}
	region, _, ok := strings.Cut(c.IdentityID, ":")
	if !ok || region == "" {
		return AWS{}, fmt.Errorf("unexpected identity ID %q", c.IdentityID)
	}
	endpoint := a.CognitoURL
	if endpoint == "" {
		endpoint = "https://cognito-identity." + region + ".amazonaws.com/"
	}
	body, _ := json.Marshal(map[string]any{
		"IdentityId": c.IdentityID,
		"Logins":     map[string]string{"cognito-identity.amazonaws.com": c.Token},
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return AWS{}, err
	}
	req.Header.Set("Content-Type", "application/x-amz-json-1.1")
	req.Header.Set("X-Amz-Target", "AWSCognitoIdentityService.GetCredentialsForIdentity")
	res, err := a.http().Do(req)
	if err != nil {
		return AWS{}, err
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return AWS{}, err
	}
	if res.StatusCode != http.StatusOK {
		var e struct {
			Type string `json:"__type"`
		}
		_ = json.Unmarshal(data, &e)
		return AWS{}, fmt.Errorf("Cognito refused the profile's token: HTTP %d %s", res.StatusCode, e.Type)
	}
	var answer struct {
		Credentials cognitoCredentials
	}
	if err := json.Unmarshal(data, &answer); err != nil {
		return AWS{}, err
	}
	return awsOf(answer.Credentials, "Cognito")
}

// awsOf are the credentials cr, which who answered.
func awsOf(cr cognitoCredentials, who string) (AWS, error) {
	if cr.AccessKeyID == "" || cr.SecretKey == "" || cr.SessionToken == "" {
		return AWS{}, errors.New(who + " answered no credentials")
	}
	return AWS{
		AccessKeyID:  cr.AccessKeyID,
		SecretKey:    cr.SecretKey,
		SessionToken: cr.SessionToken,
		Expiration:   time.UnixMilli(int64(cr.Expiration * 1000)),
	}, nil
}
