// Package session keeps the streamer's credentials for its profile: from
// the device's stream key (the command copied from the app), or a Google
// sign-in's ID token; then the auth API's credentials (which say whether
// the profile is premium) and Cognito's AWS credentials, renewed before
// they expire. Each renewal checks again that the profile is premium (and,
// signed in with Google, that the account is the profile's).
package session

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/google"
	"github.com/prodbytes/presence/presence_streamer/internal/presence"
)

// ErrFree is a free profile: the streamer streams only to premium ones (a
// "free" tier, or the auth API's Premium-only 403).
var ErrFree = presence.ErrFree

// ErrLeaseLapsed is a leading streamer that couldn't renew its lease for as
// long as a leader may be silent: another may lead by now, so it stops
// streaming until it's granted the leadership again.
var ErrLeaseLapsed = errors.New("the lease couldn't be renewed for nearly an hour: another streamer may lead now")

// Standby says whether err means the streamer must wait for the leadership
// (another streamer leads the profile), rather than stop.
func Standby(err error) bool {
	var notLeader presence.NotLeaderError
	return errors.As(err, &notLeader) || errors.Is(err, ErrLeaseLapsed)
}

// WrongProfileError is an account whose profile isn't the one asked for.
type WrongProfileError struct{ Want, Got string }

func (e WrongProfileError) Error() string {
	return fmt.Sprintf("this Google account's profile is %s, not %s: sign in with an account of %s", e.Got, e.Want, e.Want)
}

// Session is the streamer's credentials.
type Session struct {
	Google *google.Client
	API    *presence.API
	// StreamKey is the device's key; with it, no Google sign-in is used.
	StreamKey    string
	RefreshToken string
	ProfileID    string
	DeviceID     string
	// Cameras are the devices it streams for (its Blink cameras): with a
	// stream key, they join the profile's devices at each renewal.
	Cameras func() []string
	Now     func() time.Time

	mu     sync.Mutex
	creds  presence.Credentials
	aws    presence.AWS
	claims google.Claims
	// idToken is Google's latest ID token, for the lease (signed in with
	// Google), and when it expires.
	idToken        string
	idTokenExpires time.Time
}

func (s *Session) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Check signs in with idToken: the account must be the profile's, and the
// profile premium. It answers the profile's credentials.
func Check(ctx context.Context, api *presence.API, idToken, profileID, deviceID string) (presence.Credentials, error) {
	got, err := api.Profile(ctx, idToken)
	if err != nil {
		return presence.Credentials{}, err
	}
	if got != profileID {
		return presence.Credentials{}, WrongProfileError{Want: profileID, Got: got}
	}
	creds, err := api.Credentials(ctx, idToken, deviceID)
	if err != nil {
		return creds, err
	}
	if !creds.Premium() {
		return creds, ErrFree
	}
	return creds, nil
}

// CheckKey gets the profile's credentials with the device's stream key; the
// profile must be premium.
func CheckKey(ctx context.Context, api *presence.API, key, profileID, deviceID string, cameras ...string) (presence.Credentials, error) {
	creds, err := api.StreamCredentials(ctx, key, profileID, deviceID, cameras...)
	if err != nil {
		return creds, err
	}
	if !creds.Premium() {
		return creds, ErrFree
	}
	return creds, nil
}

// renew gets everything anew. Callers hold mu.
func (s *Session) renew(ctx context.Context) error {
	if s.StreamKey != "" {
		var cameras []string
		if s.Cameras != nil {
			cameras = s.Cameras()
		}
		creds, err := CheckKey(ctx, s.API, s.StreamKey, s.ProfileID, s.DeviceID, cameras...)
		if err != nil {
			return err
		}
		aws, err := s.API.AWSCredentials(ctx, creds)
		if err != nil {
			return err
		}
		s.creds, s.aws, s.claims = creds, aws, google.Claims{Subject: creds.UserID}
		return nil
	}
	idToken, claims, err := s.refreshID(ctx)
	if err != nil {
		return err
	}
	creds, err := Check(ctx, s.API, idToken, s.ProfileID, s.DeviceID)
	if err != nil {
		return err
	}
	aws, err := s.API.AWSCredentials(ctx, creds)
	if err != nil {
		return err
	}
	s.creds, s.aws, s.claims = creds, aws, claims
	return nil
}

// refreshID is a new Google ID token and its claims. Callers hold mu.
func (s *Session) refreshID(ctx context.Context) (string, google.Claims, error) {
	idToken, err := s.Google.Refresh(ctx, s.RefreshToken)
	if err != nil {
		return "", google.Claims{}, err
	}
	claims, err := google.ClaimsOf(idToken)
	if err != nil {
		return "", google.Claims{}, fmt.Errorf("Google's ID token: %w", err)
	}
	s.idToken, s.idTokenExpires = idToken, time.Unix(claims.Expiry, 0)
	return idToken, claims, nil
}

// Lease renews or asks for the device's leadership of the profile's
// streamers: only the leader streams.
func (s *Session) Lease(ctx context.Context) (presence.Lease, error) {
	if s.StreamKey != "" {
		return s.API.StreamLease(ctx, s.StreamKey, s.ProfileID, s.DeviceID)
	}
	s.mu.Lock()
	idToken := s.idToken
	if idToken == "" || s.now().Add(5*time.Minute).After(s.idTokenExpires) {
		var err error
		if idToken, _, err = s.refreshID(ctx); err != nil {
			s.mu.Unlock()
			return presence.Lease{}, err
		}
	}
	s.mu.Unlock()
	return s.API.ProfileLease(ctx, idToken, s.DeviceID)
}

// Register renews now, so new cameras (Cameras) join the profile's
// devices at once.
func (s *Session) Register(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.renew(ctx)
}

// AWS is current AWS credentials for the profile's folder, renewed five
// minutes before they expire.
func (s *Session) AWS(ctx context.Context) (presence.AWS, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.aws.AccessKeyID == "" || s.now().Add(5*time.Minute).After(s.aws.Expiration) {
		if err := s.renew(ctx); err != nil {
			return presence.AWS{}, err
		}
	}
	return s.aws, nil
}

// Credentials are the auth API's credentials, after a renewal if needed.
func (s *Session) Credentials(ctx context.Context) (presence.Credentials, error) {
	if _, err := s.AWS(ctx); err != nil {
		return presence.Credentials{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.creds, nil
}

// UserID is the signed-in account's Google ID (an event's `userId`), or
// with a stream key, the ID of who made the key.
func (s *Session) UserID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.claims.Subject
}

// Fatal says whether err means the streamer must stop streaming: a free
// profile, another profile, a device past the plan's limit, or a sign-in
// that no longer works; or another
// streamer leading the profile ([Standby]: it waits for the leadership).
// Other errors (the network) pass.
func Fatal(err error) bool {
	var wrong WrongProfileError
	return Standby(err) || errors.Is(err, ErrFree) || errors.As(err, &wrong) ||
		errors.Is(err, google.ErrRevoked) || errors.Is(err, presence.ErrUnauthorized) ||
		errors.Is(err, presence.ErrKeyRefused) || errors.Is(err, presence.ErrDeviceLimit)
}
