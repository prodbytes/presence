// Package state keeps what the streamer must remember across restarts:
// the profile it streams to, its device ID and media key (made once, like a
// phone's, or given by the app's command), and its stream key or Google
// sign-in. It's one JSON file, readable only by its owner: the stream key,
// the refresh token and the media key are secrets.
package state

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"syscall"

	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// State is the streamer's state.
type State struct {
	ProfileID string `json:"profileId,omitempty"`
	DeviceID  string `json:"deviceId"`
	// MediaKey is the device's AES-256 key, base64.
	MediaKey string `json:"mediaKey"`
	// StreamKey is the device's key from the app's command (psk_…): with
	// it, there's no Google sign-in.
	StreamKey string `json:"streamKey,omitempty"`
	// RefreshToken is the Google sign-in's; Email whose it is.
	RefreshToken string `json:"refreshToken,omitempty"`
	Email        string `json:"email,omitempty"`

	path string
}

// Load reads the state in dir, or makes a new one (a new device ID and
// key, saved at once) when there's none.
func Load(dir string) (*State, error) {
	path := filepath.Join(dir, "state.json")
	s := &State{path: path}
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(data, s); err != nil {
			return nil, errors.New(path + " is damaged: " + err.Error())
		}
	case !os.IsNotExist(err):
		return nil, err
	}
	if s.DeviceID == "" || s.MediaKey == "" {
		key, err := seal.NewKey()
		if err != nil {
			return nil, err
		}
		s.DeviceID = ids.NewDevice()
		s.MediaKey = base64.StdEncoding.EncodeToString(key)
		if err := s.Save(); err != nil {
			return nil, err
		}
	}
	if !ids.DevicePattern.MatchString(s.DeviceID) {
		return nil, errors.New(path + ": the device ID isn't one")
	}
	if key, err := s.Key(); err != nil || len(key) != seal.KeyLength {
		return nil, errors.New(path + ": the media key isn't one")
	}
	return s, nil
}

// Lock takes the state folder for this process, or fails when another
// streamer has it. unlock gives it back (the system does when the process
// ends).
func Lock(dir string) (unlock func(), err error) {
	f, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, errors.New("another presence-streamer runs with " + dir + " (the service? sudo systemctl stop presence-streamer)")
	}
	return func() { f.Close() }, nil
}

// Key is the device's media key.
func (s *State) Key() ([]byte, error) {
	return base64.StdEncoding.DecodeString(s.MediaKey)
}

// Save writes the state (to a new file, then moved into place).
func (s *State) Save() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// SignOut forgets the Google sign-in and the stream key.
func (s *State) SignOut() error {
	s.RefreshToken, s.Email, s.StreamKey = "", "", ""
	return s.Save()
}
