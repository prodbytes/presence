// Package wstest is a WebSocket server's side, for tests: it upgrades an
// HTTP request, reads the client's (masked) frames and writes frames as
// they are given, well-formed or not.
package wstest

import (
	"bufio"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
)

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Conn is the server's end of a WebSocket.
type Conn struct {
	net.Conn
	r   *bufio.Reader
	wmu sync.Mutex
	// buf is the rest of the binary message being read (Read).
	buf []byte
}

// Upgrade answers the WebSocket handshake of r, choosing protocol when the
// client asks for it.
func Upgrade(w http.ResponseWriter, r *http.Request, protocol string) (*Conn, error) {
	key := r.Header.Get("Sec-WebSocket-Key")
	if r.Header.Get("Sec-WebSocket-Version") != "13" || key == "" {
		http.Error(w, "not a websocket", http.StatusBadRequest)
		return nil, errors.New("not a websocket handshake")
	}
	conn, rw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		return nil, err
	}
	sum := sha1.Sum([]byte(key + guid))
	answer := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + base64.StdEncoding.EncodeToString(sum[:]) + "\r\n"
	if protocol != "" && r.Header.Get("Sec-WebSocket-Protocol") == protocol {
		answer += "Sec-WebSocket-Protocol: " + protocol + "\r\n"
	}
	if _, err := io.WriteString(conn, answer+"\r\n"); err != nil {
		conn.Close()
		return nil, err
	}
	return &Conn{Conn: conn, r: rw.Reader}, nil
}

// WriteFrame writes one unmasked frame.
func (c *Conn) WriteFrame(fin bool, op byte, payload []byte) error {
	b := []byte{op}
	if fin {
		b[0] |= 0x80
	}
	switch n := len(payload); {
	case n < 126:
		b = append(b, byte(n))
	case n <= 0xFFFF:
		b = append(b, 126, byte(n>>8), byte(n))
	default:
		b = append(b, 127)
		b = binary.BigEndian.AppendUint64(b, uint64(n))
	}
	return c.WriteRaw(append(b, payload...))
}

// WriteRaw writes bytes as they are.
func (c *Conn) WriteRaw(b []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err := c.Conn.Write(b)
	return err
}

// Write sends p as one binary message.
func (c *Conn) Write(p []byte) (int, error) {
	if err := c.WriteFrame(true, 0x2, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// ReadFrame reads one frame, unmasked, and whether the client masked it.
func (c *Conn) ReadFrame() (fin bool, op byte, payload []byte, masked bool, err error) {
	var head [2]byte
	if _, err = io.ReadFull(c.r, head[:]); err != nil {
		return
	}
	fin, op, masked = head[0]&0x80 != 0, head[0]&0x0F, head[1]&0x80 != 0
	length := uint64(head[1] & 0x7F)
	switch length {
	case 126:
		var ext [2]byte
		if _, err = io.ReadFull(c.r, ext[:]); err != nil {
			return
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err = io.ReadFull(c.r, ext[:]); err != nil {
			return
		}
		length = binary.BigEndian.Uint64(ext[:])
	}
	if length > 1<<20 {
		err = errors.New("wstest: frame too big")
		return
	}
	var mask [4]byte
	if masked {
		if _, err = io.ReadFull(c.r, mask[:]); err != nil {
			return
		}
	}
	payload = make([]byte, length)
	if _, err = io.ReadFull(c.r, payload); err != nil {
		return
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return
}

// Read gives the client's binary messages' bytes as a stream, answering
// pings; io.EOF at a close frame, an error for an unmasked frame.
func (c *Conn) Read(p []byte) (int, error) {
	for len(c.buf) == 0 {
		_, op, payload, masked, err := c.ReadFrame()
		if err != nil {
			return 0, err
		}
		if !masked {
			return 0, errors.New("wstest: an unmasked frame from the client")
		}
		switch op {
		case 0x8:
			return 0, io.EOF
		case 0x9:
			c.WriteFrame(true, 0xA, payload)
		case 0x0, 0x2:
			c.buf = payload
		}
	}
	n := copy(p, c.buf)
	c.buf = c.buf[n:]
	return n, nil
}
