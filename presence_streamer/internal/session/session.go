// Package session keeps the streamer's credentials for its profile: the
// Google sign-in's ID token, the auth API's credentials (which say whether
// the profile is premium) and Cognito's AWS credentials, renewed before
// they expire. Each renewal checks again that the account is the
// profile's and that it's premium.
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

// ErrFree is a free profile: the streamer streams only to premium ones.
var ErrFree = errors.New("this profile is free: the streamer needs a Premium profile (cloud backup)")

// WrongProfileError is an account whose profile isn't the one asked for.
type WrongProfileError struct{ Want, Got string }

func (e WrongProfileError) Error() string {
	return fmt.Sprintf("this Google account's profile is %s, not %s: sign in with an account of %s", e.Got, e.Want, e.Want)
}

// Session is the streamer's credentials.
type Session struct {
	Google       *google.Client
	API          *presence.API
	RefreshToken string
	ProfileID    string
	DeviceID     string
	Now          func() time.Time

	mu     sync.Mutex
	creds  presence.Credentials
	aws    presence.AWS
	claims google.Claims
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

// renew gets everything anew. Callers hold mu.
func (s *Session) renew(ctx context.Context) error {
	idToken, err := s.Google.Refresh(ctx, s.RefreshToken)
	if err != nil {
		return err
	}
	claims, err := google.ClaimsOf(idToken)
	if err != nil {
		return fmt.Errorf("Google's ID token: %w", err)
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

// UserID is the signed-in account's Google ID (an event's `userId`).
func (s *Session) UserID() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.claims.Subject
}

// Fatal says whether err means the streamer must stop: a free profile,
// another profile, or a sign-in that no longer works. Other errors (the
// network) pass.
func Fatal(err error) bool {
	var wrong WrongProfileError
	return errors.Is(err, ErrFree) || errors.As(err, &wrong) ||
		errors.Is(err, google.ErrRevoked) || errors.Is(err, presence.ErrUnauthorized)
}
