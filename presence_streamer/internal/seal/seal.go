// Package seal seals media the way the app does (SealFormat, in
// presence_app/lib/crypto/seal_format.dart), so the profile's other
// devices open what the streamer uploads.
//
// A sealed object is a header, then the media in chunks, each encrypted
// with AES-256-GCM:
//
//	4  magic: "PSE" and the format version, 1
//	1  the key ID's length, n (1 to 64)
//	n  the key ID: the ID of the device whose key sealed it (ASCII)
//	4  the chunk size, big-endian (256 KB)
//	7  a random nonce prefix, new for each object
//
// Each chunk is up to the chunk size of media, then its 16-byte GCM tag;
// empty media is one empty chunk. A chunk's nonce is the prefix, its index
// (4 bytes, big-endian) and a byte that's 1 for the last chunk, 0 for the
// others. The header is every chunk's additional authenticated data.
package seal

import (
	"bufio"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
)

// ChunkSize is how much media each chunk holds.
const ChunkSize = 256 * 1024

// KeyLength is the length of a device's key (AES-256).
const KeyLength = 32

const (
	tagLength    = 16
	prefixLength = 7
)

var (
	magic        = []byte{0x50, 0x53, 0x45, 0x01}
	keyIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
)

// ErrBroken is returned when sealed media doesn't open: not sealed,
// changed, cut off, or another key.
var ErrBroken = errors.New("sealed media is broken")

// NewKey makes a new random device key.
func NewKey() ([]byte, error) {
	key := make([]byte, KeyLength)
	_, err := rand.Read(key)
	return key, err
}

// Header is a sealed object's header for a key ID, with prefix as its
// nonce prefix (random when nil).
func Header(keyID string, prefix []byte) ([]byte, error) {
	if !keyIDPattern.MatchString(keyID) {
		return nil, fmt.Errorf("seal: %q isn't a safe key ID", keyID)
	}
	if prefix == nil {
		prefix = make([]byte, prefixLength)
		if _, err := rand.Read(prefix); err != nil {
			return nil, err
		}
	}
	if len(prefix) != prefixLength {
		return nil, fmt.Errorf("seal: nonce prefix must be %d bytes", prefixLength)
	}
	h := append([]byte{}, magic...)
	h = append(h, byte(len(keyID)))
	h = append(h, keyID...)
	h = binary.BigEndian.AppendUint32(h, ChunkSize)
	return append(h, prefix...), nil
}

func nonce(header []byte, index uint32, last bool) []byte {
	n := append([]byte{}, header[len(header)-prefixLength:]...)
	n = binary.BigEndian.AppendUint32(n, index)
	if last {
		return append(n, 1)
	}
	return append(n, 0)
}

func gcm(key []byte) (cipher.AEAD, error) {
	if len(key) != KeyLength {
		return nil, fmt.Errorf("seal: key must be %d bytes", KeyLength)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// Seal writes in to out sealed with key, the key of device keyID, a chunk
// at a time. prefix is the nonce prefix (nil: random; tests fix it).
func Seal(out io.Writer, in io.Reader, key []byte, keyID string, prefix []byte) error {
	aead, err := gcm(key)
	if err != nil {
		return err
	}
	header, err := Header(keyID, prefix)
	if err != nil {
		return err
	}
	if _, err := out.Write(header); err != nil {
		return err
	}
	// Read one chunk ahead, to know which one is last.
	cur := make([]byte, ChunkSize)
	next := make([]byte, ChunkSize)
	n, err := io.ReadFull(in, cur)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		return err
	}
	sealed := make([]byte, 0, ChunkSize+tagLength)
	for index := uint32(0); ; index++ {
		m := 0
		if n == ChunkSize {
			m, err = io.ReadFull(in, next)
			if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
				return err
			}
		}
		last := m == 0
		sealed = aead.Seal(sealed[:0], nonce(header, index, last), cur[:n], header)
		if _, err := out.Write(sealed); err != nil {
			return err
		}
		if last {
			return nil
		}
		cur, next, n = next, cur, m
	}
}

// Open reads sealed media from in and writes the media to out.
func Open(out io.Writer, in io.Reader, key []byte) error {
	aead, err := gcm(key)
	if err != nil {
		return err
	}
	r := bufio.NewReader(in)
	start, err := r.Peek(len(magic) + 1)
	if err != nil || string(start[:len(magic)]) != string(magic) {
		return ErrBroken
	}
	n := int(start[len(magic)])
	if n < 1 || n > 64 {
		return ErrBroken
	}
	header := make([]byte, len(magic)+1+n+4+prefixLength)
	if _, err := io.ReadFull(r, header); err != nil {
		return ErrBroken
	}
	size := binary.BigEndian.Uint32(header[len(magic)+1+n:])
	if size < 1024 || size > 16*1024*1024 {
		return ErrBroken
	}
	full := int(size) + tagLength
	cur := make([]byte, full)
	next := make([]byte, full)
	c, err := io.ReadFull(r, cur)
	if err != nil && err != io.ErrUnexpectedEOF {
		return ErrBroken
	}
	for index := uint32(0); ; index++ {
		m := 0
		if c == full {
			m, err = io.ReadFull(r, next)
			if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
				return err
			}
		}
		last := m == 0
		if c < tagLength {
			return ErrBroken
		}
		plain, err := aead.Open(nil, nonce(header, index, last), cur[:c], header)
		if err != nil {
			return ErrBroken
		}
		if _, err := out.Write(plain); err != nil {
			return err
		}
		if last {
			return nil
		}
		cur, next, c = next, cur, m
	}
}

// File seals the file src into dst (written as dst.part, then moved into
// place), with key, the key of device keyID.
func File(src, dst string, key []byte, keyID string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	part := dst + ".part"
	out, err := os.OpenFile(part, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	w := bufio.NewWriterSize(out, 64*1024)
	err = Seal(w, in, key, keyID, nil)
	if err == nil {
		err = w.Flush()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(part)
		return err
	}
	return os.Rename(part, dst)
}
