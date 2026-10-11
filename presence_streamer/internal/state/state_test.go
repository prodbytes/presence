package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestState(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	s, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if s.DeviceID == "" || s.MediaKey == "" {
		t.Fatal("no device ID or key made")
	}
	info, _ := os.Stat(filepath.Join(dir, "state.json"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("state.json is %v, want 0600", info.Mode().Perm())
	}
	s.ProfileID, s.RefreshToken = "automatic_paranoid_axolotl", "rt"
	if err := s.Save(); err != nil {
		t.Fatal(err)
	}
	again, err := Load(dir)
	if err != nil || again.DeviceID != s.DeviceID || again.MediaKey != s.MediaKey || again.RefreshToken != "rt" {
		t.Fatalf("reloaded %+v, %v", again, err)
	}
	again.SignOut()
	if after, _ := Load(dir); after.RefreshToken != "" || after.ProfileID == "" {
		t.Fatalf("after sign-out %+v", after)
	}
	unlock, err := Lock(dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Lock(dir); err == nil {
		t.Fatal("locked twice")
	}
	unlock()
	if unlock, err := Lock(dir); err != nil {
		t.Fatal("not lockable after unlocking")
	} else {
		unlock()
	}
	os.WriteFile(filepath.Join(dir, "state.json"), []byte("{"), 0o600)
	if _, err := Load(dir); err == nil {
		t.Fatal("a damaged state loaded")
	}
}
