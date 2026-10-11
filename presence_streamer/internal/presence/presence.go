// Package presence asks the auth API who the signed-in account is and for
// its profile's credentials, as the app does (see specs/auth-api.md and
// specs/cloud-sync.md), and trades them with Cognito for AWS credentials.
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
	"time"
)

// API is the auth API of a Presence site (https://presence.nu01.com).
type API struct {
	BaseURL string
	HTTP    *http.Client
	// CognitoURL overrides Cognito's endpoint (tests); empty is AWS's for
	// the identity's region.
	CognitoURL string
}

// ErrUnauthorized is the auth API refusing the ID token (expired, or not
// for its client).
var ErrUnauthorized = errors.New("the auth API refused the Google sign-in")

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

func (a *API) call(ctx context.Context, method, path, idToken string, body io.Reader, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(a.BaseURL, "/")+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+idToken)
	if body != nil {
		req.Header.Set("Content-Type", "text/plain")
	}
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
		return ErrUnauthorized
	case res.StatusCode != http.StatusOK:
		var e struct {
			Error string `json:"error"`
		}
		_ = json.Unmarshal(data, &e)
		return fmt.Errorf("%s %s: HTTP %d %s", method, path, res.StatusCode, e.Error)
	}
	return json.Unmarshal(data, out)
}

// Profile is the signed-in account's profile ID (GET /api/auth/profile).
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
	return c, err
}

// AWSCredentials trades the auth API's token with Cognito
// (GetCredentialsForIdentity, unsigned: the token is the proof).
func (a *API) AWSCredentials(ctx context.Context, c Credentials) (AWS, error) {
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
		Credentials struct {
			AccessKeyID  string  `json:"AccessKeyId"`
			SecretKey    string  `json:"SecretKey"`
			SessionToken string  `json:"SessionToken"`
			Expiration   float64 `json:"Expiration"`
		}
	}
	if err := json.Unmarshal(data, &answer); err != nil {
		return AWS{}, err
	}
	cr := answer.Credentials
	if cr.AccessKeyID == "" || cr.SecretKey == "" || cr.SessionToken == "" {
		return AWS{}, errors.New("Cognito answered no credentials")
	}
	return AWS{
		AccessKeyID:  cr.AccessKeyID,
		SecretKey:    cr.SecretKey,
		SessionToken: cr.SessionToken,
		Expiration:   time.UnixMilli(int64(cr.Expiration * 1000)),
	}, nil
}
