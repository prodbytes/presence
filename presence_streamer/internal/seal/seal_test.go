package seal

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The fixture the app's test (presence_app/test/streamer_seal_test.dart)
// opens with SealFormat: a fixed key, key ID, nonce prefix and media.
const fixture = "../../testdata/sealed-fixture.bin"

func fixtureKey() []byte {
	key := make([]byte, KeyLength)
	for i := range key {
		key[i] = byte(i)
	}
	return key
}

// fixtureMedia is 300,000 bytes (two chunks, the last one short): byte i
// is i*31 mod 251.
func fixtureMedia() []byte {
	media := make([]byte, 300000)
	for i := range media {
		media[i] = byte(i * 31 % 251)
	}
	return media
}

func sealed(t *testing.T, media []byte, prefix []byte) []byte {
	t.Helper()
	var out bytes.Buffer
	if err := Seal(&out, bytes.NewReader(media), fixtureKey(), "streamer_test_device", prefix); err != nil {
		t.Fatal(err)
	}
	return out.Bytes()
}

func TestRoundTripEverySize(t *testing.T) {
	for _, size := range []int{0, 1, 1000, ChunkSize - 1, ChunkSize, ChunkSize + 1, 300000} {
		media := fixtureMedia()[:size]
		s := sealed(t, media, nil)
		chunks := (size + ChunkSize - 1) / ChunkSize
		if size == 0 {
			chunks = 1
		}
		header := 4 + 1 + len("streamer_test_device") + 4 + 7
		if want := header + size + chunks*tagLength; len(s) != want {
			t.Fatalf("size %d: sealed %d bytes, want %d", size, len(s), want)
		}
		var out bytes.Buffer
		if err := Open(&out, bytes.NewReader(s), fixtureKey()); err != nil {
			t.Fatalf("size %d: %v", size, err)
		}
		if !bytes.Equal(out.Bytes(), media) {
			t.Fatalf("size %d: opened media differs", size)
		}
	}
}

func TestNeverTheSameTwice(t *testing.T) {
	if bytes.Equal(sealed(t, []byte("x"), nil), sealed(t, []byte("x"), nil)) {
		t.Fatal("two seals of the same media are equal")
	}
}

func TestBrokenDoesNotOpen(t *testing.T) {
	s := sealed(t, fixtureMedia(), nil)
	other := fixtureKey()
	other[0] ^= 1
	changed := append([]byte{}, s...)
	changed[len(changed)/2] ^= 1
	renamed := append([]byte{}, s...)
	renamed[5] = 'x'
	// Cut at a chunk boundary: the chunk before isn't marked last.
	header := 4 + 1 + len("streamer_test_device") + 4 + 7
	cut := s[:header+ChunkSize+tagLength]
	for name, c := range map[string]struct {
		data []byte
		key  []byte
	}{
		"another key": {s, other},
		"changed":     {changed, fixtureKey()},
		"renamed key": {renamed, fixtureKey()},
		"cut off":     {cut, fixtureKey()},
		"not sealed":  {[]byte("plain media"), fixtureKey()},
	} {
		if err := Open(&bytes.Buffer{}, bytes.NewReader(c.data), c.key); err != ErrBroken {
			t.Errorf("%s: got %v, want ErrBroken", name, err)
		}
	}
}

func TestUnsafeKeyID(t *testing.T) {
	if err := Seal(&bytes.Buffer{}, bytes.NewReader(nil), fixtureKey(), "../x", nil); err == nil {
		t.Fatal("sealed with an unsafe key ID")
	}
}

func TestFile(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "clip.mp4")
	dst := filepath.Join(dir, "clip.sealed")
	if err := os.WriteFile(src, fixtureMedia(), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := File(src, dst, fixtureKey(), "streamer_test_device"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dst + ".part"); !os.IsNotExist(err) {
		t.Fatal("the .part file was left behind")
	}
	data, _ := os.ReadFile(dst)
	var out bytes.Buffer
	if err := Open(&out, bytes.NewReader(data), fixtureKey()); err != nil || !bytes.Equal(out.Bytes(), fixtureMedia()) {
		t.Fatalf("the sealed file doesn't open to the media: %v", err)
	}
}

// The committed fixture is what Seal makes with a fixed prefix; set
// UPDATE_FIXTURE=1 to write it again.
func TestFixture(t *testing.T) {
	got := sealed(t, fixtureMedia(), []byte{1, 2, 3, 4, 5, 6, 7})
	if os.Getenv("UPDATE_FIXTURE") == "1" {
		if err := os.WriteFile(fixture, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("Seal no longer makes the committed fixture")
	}
}
