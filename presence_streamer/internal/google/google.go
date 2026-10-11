// Package google signs the streamer in with Google's OAuth device flow
// (for devices without a browser or keyboard): it shows a code, someone
// enters it at google.com/device on a phone, and the streamer gets a
// refresh token, which it trades for ID tokens from then on.
package google

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Endpoints are Google's OAuth endpoints (tests point them elsewhere).
type Endpoints struct {
	DeviceCode string
	Token      string
}

// Google's.
var Google = Endpoints{
	DeviceCode: "https://oauth2.googleapis.com/device/code",
	Token:      "https://oauth2.googleapis.com/token",
}

// Client is a "TVs and Limited Input devices" OAuth client. Google's
// device flow needs its secret, which for that kind of client isn't
// confidential (it ships with the app).
type Client struct {
	ID, Secret string
	Endpoints  Endpoints
	HTTP       *http.Client
	// Sleep waits between polls (tests make it instant).
	Sleep func(context.Context, time.Duration) error
}

// Code is what someone enters to sign the streamer in.
type Code struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURL string `json:"verification_url"`
	ExpiresIn       int    `json:"expires_in"`
	Interval        int    `json:"interval"`
}

// Tokens are a sign-in's tokens.
type Tokens struct {
	IDToken      string `json:"id_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
}

// ErrDenied is returned when the sign-in was refused, or the code expired.
var ErrDenied = errors.New("the sign-in was refused or the code expired")

// ErrRevoked is returned when the refresh token no longer works: sign in
// again.
var ErrRevoked = errors.New("the Google sign-in was revoked or expired: sign in again")

type oauthError struct {
	Error       string `json:"error"`
	Description string `json:"error_description"`
}

func (c *Client) http() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return &http.Client{Timeout: 30 * time.Second}
}

func (c *Client) post(ctx context.Context, endpoint string, form url.Values, out any) (int, oauthError, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return 0, oauthError{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := c.http().Do(req)
	if err != nil {
		return 0, oauthError{}, err
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return res.StatusCode, oauthError{}, err
	}
	if res.StatusCode != http.StatusOK {
		var e oauthError
		_ = json.Unmarshal(body, &e)
		return res.StatusCode, e, nil
	}
	return res.StatusCode, oauthError{}, json.Unmarshal(body, out)
}

// RequestCode starts a sign-in: the code to show.
func (c *Client) RequestCode(ctx context.Context) (Code, error) {
	var code Code
	status, e, err := c.post(ctx, c.Endpoints.DeviceCode, url.Values{
		"client_id": {c.ID},
		"scope":     {"openid email"},
	}, &code)
	if err != nil {
		return code, err
	}
	if status != http.StatusOK {
		return code, fmt.Errorf("Google refused a sign-in code (HTTP %d %s: %s)", status, e.Error, e.Description)
	}
	if code.Interval <= 0 {
		code.Interval = 5
	}
	return code, nil
}

func sleep(ctx context.Context, d time.Duration) error {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

// Wait polls until someone has entered code, and returns the tokens.
func (c *Client) Wait(ctx context.Context, code Code) (Tokens, error) {
	wait := c.Sleep
	if wait == nil {
		wait = sleep
	}
	interval := time.Duration(code.Interval) * time.Second
	deadline := time.Now().Add(time.Duration(code.ExpiresIn) * time.Second)
	for {
		if err := wait(ctx, interval); err != nil {
			return Tokens{}, err
		}
		var tokens Tokens
		status, e, err := c.post(ctx, c.Endpoints.Token, url.Values{
			"client_id":     {c.ID},
			"client_secret": {c.Secret},
			"device_code":   {code.DeviceCode},
			"grant_type":    {"urn:ietf:params:oauth:grant-type:device_code"},
		}, &tokens)
		switch {
		case err != nil:
			// A network error: keep polling until the code expires.
		case status == http.StatusOK:
			if tokens.IDToken == "" || tokens.RefreshToken == "" {
				return tokens, errors.New("Google's answer has no ID or refresh token")
			}
			return tokens, nil
		case e.Error == "authorization_pending":
		case e.Error == "slow_down":
			interval += 5 * time.Second
		case e.Error == "access_denied" || e.Error == "expired_token":
			return tokens, ErrDenied
		default:
			return tokens, fmt.Errorf("Google refused the sign-in (HTTP %d %s: %s)", status, e.Error, e.Description)
		}
		if code.ExpiresIn > 0 && time.Now().After(deadline) {
			return tokens, ErrDenied
		}
	}
}

// Refresh trades the refresh token for a new ID token.
func (c *Client) Refresh(ctx context.Context, refreshToken string) (string, error) {
	var tokens Tokens
	status, e, err := c.post(ctx, c.Endpoints.Token, url.Values{
		"client_id":     {c.ID},
		"client_secret": {c.Secret},
		"refresh_token": {refreshToken},
		"grant_type":    {"refresh_token"},
	}, &tokens)
	if err != nil {
		return "", err
	}
	if status == http.StatusBadRequest && e.Error == "invalid_grant" {
		return "", ErrRevoked
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("Google refused to refresh the sign-in (HTTP %d %s)", status, e.Error)
	}
	if tokens.IDToken == "" {
		return "", errors.New("Google's answer has no ID token")
	}
	return tokens.IDToken, nil
}

// Claims are the ID token's claims the streamer reads. It doesn't verify
// the token: it got it from Google over TLS, and the auth API verifies it.
type Claims struct {
	Subject string `json:"sub"`
	Email   string `json:"email"`
	Expiry  int64  `json:"exp"`
}

// ClaimsOf reads an ID token's claims.
func ClaimsOf(idToken string) (Claims, error) {
	var claims Claims
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return claims, errors.New("not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return claims, err
	}
	return claims, json.Unmarshal(payload, &claims)
}
