// Package ws is a small WebSocket client (RFC 6455) for live sync's MQTT
// connection: it dials a ws:// or wss:// URL with one subprotocol, and
// carries binary messages as a byte stream (MQTT packets may span
// messages, or share one). Text messages, extensions and masked server
// frames are refused; pings are answered; every read is bounded.
package ws

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// MaxMessage is the largest message accepted by default: AWS IoT's
// messages are at most 128 KB.
const MaxMessage = 256 << 10

// maxHandshake is the most the server's handshake answer may take.
const maxHandshake = 16 << 10

const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Opcodes.
const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

// ErrProtocol is a frame the client won't take.
var ErrProtocol = errors.New("websocket protocol error")

// Options are a Dial's.
type Options struct {
	// Subprotocol is asked for (Sec-WebSocket-Protocol), e.g. "mqtt";
	// the server must accept it, or say none.
	Subprotocol string
	// TLS is the wss:// connection's configuration (tests: their CA);
	// nil verifies against the system's roots.
	TLS *tls.Config
	// MaxMessage is the largest message taken; 0 is [MaxMessage].
	MaxMessage int
	// Dialer dials TCP; nil is a net.Dialer.
	Dialer *net.Dialer
}

// Conn is an open WebSocket: Read gives the binary messages' bytes in
// order, Write sends each call as one binary message.
type Conn struct {
	conn net.Conn
	r    *bufio.Reader
	max  int

	wmu    sync.Mutex
	closed bool

	// buf is the rest of the message being read.
	buf []byte
}

// Dial opens a WebSocket to rawURL (ws:// or wss://). Its errors never
// quote the URL: a presigned one holds credentials in its query.
func Dial(ctx context.Context, rawURL string, o Options) (*Conn, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, errors.New("websocket: a malformed URL")
	}
	var secure bool
	switch u.Scheme {
	case "wss":
		secure = true
	case "ws":
	default:
		return nil, fmt.Errorf("websocket: scheme %q", u.Scheme)
	}
	host := u.Hostname()
	port := u.Port()
	if port == "" {
		port = "80"
		if secure {
			port = "443"
		}
	}
	dialer := o.Dialer
	if dialer == nil {
		dialer = &net.Dialer{Timeout: 15 * time.Second}
	}
	raw, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(host, port))
	if err != nil {
		return nil, fmt.Errorf("websocket: connecting to %s: %w", host, scrub(err))
	}
	conn := raw
	if secure {
		cfg := &tls.Config{MinVersion: tls.VersionTLS12}
		if o.TLS != nil {
			cfg = o.TLS.Clone()
		}
		if cfg.ServerName == "" {
			cfg.ServerName = host
		}
		tc := tls.Client(raw, cfg)
		if err := tc.HandshakeContext(ctx); err != nil {
			raw.Close()
			return nil, fmt.Errorf("websocket: TLS with %s: %w", host, err)
		}
		conn = tc
	}
	// The handshake may take until ctx ends.
	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	}
	stop := context.AfterFunc(ctx, func() { conn.SetDeadline(time.Unix(1, 0)) })
	c, err := handshake(conn, u, o)
	stop()
	if err != nil {
		conn.Close()
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, err
	}
	conn.SetDeadline(time.Time{})
	return c, nil
}

// scrub is err without the URL a net error may carry.
func scrub(err error) error {
	var op *net.OpError
	if errors.As(err, &op) && op.Err != nil {
		return op.Err
	}
	return err
}

// capped reads at most n bytes in all from r, while n >= 0 (the handshake),
// then reads freely once n is set below 0.
type capped struct {
	r io.Reader
	n int
}

func (c *capped) Read(p []byte) (int, error) {
	if c.n < 0 {
		return c.r.Read(p)
	}
	if c.n == 0 {
		return 0, errors.New("websocket: the handshake answer is too long")
	}
	if len(p) > c.n {
		p = p[:c.n]
	}
	n, err := c.r.Read(p)
	c.n -= n
	return n, err
}

func handshake(conn net.Conn, u *url.URL, o Options) (*Conn, error) {
	nonce := make([]byte, 16)
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(nonce)
	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	if u.RawQuery != "" {
		path += "?" + u.RawQuery
	}
	var req strings.Builder
	fmt.Fprintf(&req, "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n", path, u.Host)
	fmt.Fprintf(&req, "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n", key)
	if o.Subprotocol != "" {
		fmt.Fprintf(&req, "Sec-WebSocket-Protocol: %s\r\n", o.Subprotocol)
	}
	req.WriteString("\r\n")
	if _, err := io.WriteString(conn, req.String()); err != nil {
		return nil, fmt.Errorf("websocket: sending the handshake: %w", scrub(err))
	}
	limit := &capped{r: conn, n: maxHandshake}
	r := bufio.NewReaderSize(limit, 4096)
	resp, err := http.ReadResponse(r, &http.Request{Method: http.MethodGet})
	if err != nil {
		return nil, fmt.Errorf("websocket: reading the handshake: %w", scrub(err))
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		// Not the body: the status says enough, and is all that's trusted.
		return nil, fmt.Errorf("websocket: the server answered %d %s", resp.StatusCode, http.StatusText(resp.StatusCode))
	}
	if !strings.EqualFold(resp.Header.Get("Upgrade"), "websocket") || !headerHas(resp.Header, "Connection", "upgrade") {
		return nil, errors.New("websocket: the server didn't upgrade the connection")
	}
	sum := sha1.Sum([]byte(key + guid))
	if resp.Header.Get("Sec-WebSocket-Accept") != base64.StdEncoding.EncodeToString(sum[:]) {
		return nil, errors.New("websocket: a wrong Sec-WebSocket-Accept")
	}
	if p := resp.Header.Get("Sec-WebSocket-Protocol"); p != "" && p != o.Subprotocol {
		return nil, fmt.Errorf("websocket: the server chose subprotocol %q", p)
	}
	if resp.Header.Get("Sec-WebSocket-Extensions") != "" {
		return nil, errors.New("websocket: the server chose an extension none was asked for")
	}
	limit.n = -1
	max := o.MaxMessage
	if max <= 0 {
		max = MaxMessage
	}
	return &Conn{conn: conn, r: r, max: max}, nil
}

// headerHas says whether the comma-separated header name has token (case
// insensitive).
func headerHas(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, t := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(t), token) {
				return true
			}
		}
	}
	return false
}

// Read reads the binary messages' bytes, in order. io.EOF: the server
// closed the WebSocket.
func (c *Conn) Read(p []byte) (int, error) {
	for len(c.buf) == 0 {
		msg, err := c.readMessage()
		if err != nil {
			return 0, err
		}
		c.buf = msg
	}
	n := copy(p, c.buf)
	c.buf = c.buf[n:]
	return n, nil
}

// readMessage reads frames until a whole data message, answering control
// frames on the way.
func (c *Conn) readMessage() ([]byte, error) {
	var msg []byte
	started := false
	for {
		fin, op, payload, err := c.readFrame()
		if err != nil {
			return nil, err
		}
		switch op {
		case opPing:
			if err := c.writeFrame(opPong, payload); err != nil {
				return nil, err
			}
			continue
		case opPong:
			continue
		case opClose:
			// Answered with the code it sent (or none), then closed.
			code := payload
			if len(code) > 2 {
				code = code[:2]
			}
			c.close(code)
			return nil, io.EOF
		case opText:
			return nil, fmt.Errorf("%w: a text message", ErrProtocol)
		case opBinary:
			if started {
				return nil, fmt.Errorf("%w: a new message inside a fragmented one", ErrProtocol)
			}
			started = true
		case opContinuation:
			if !started {
				return nil, fmt.Errorf("%w: a continuation without a message", ErrProtocol)
			}
		default:
			return nil, fmt.Errorf("%w: opcode %d", ErrProtocol, op)
		}
		if len(msg)+len(payload) > c.max {
			return nil, fmt.Errorf("%w: a message over %d bytes", ErrProtocol, c.max)
		}
		msg = append(msg, payload...)
		if fin {
			if len(msg) == 0 {
				// Nothing for the stream; the next one.
				started = false
				continue
			}
			return msg, nil
		}
	}
}

// readFrame reads one frame: its FIN bit, opcode and payload.
func (c *Conn) readFrame() (bool, byte, []byte, error) {
	var head [2]byte
	if _, err := io.ReadFull(c.r, head[:]); err != nil {
		return false, 0, nil, err
	}
	fin := head[0]&0x80 != 0
	if head[0]&0x70 != 0 {
		return false, 0, nil, fmt.Errorf("%w: reserved bits set", ErrProtocol)
	}
	op := head[0] & 0x0F
	if head[1]&0x80 != 0 {
		return false, 0, nil, fmt.Errorf("%w: a masked frame from the server", ErrProtocol)
	}
	length := uint64(head[1] & 0x7F)
	switch length {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(c.r, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(ext[:]))
		if length < 126 {
			return false, 0, nil, fmt.Errorf("%w: a length not in its shortest form", ErrProtocol)
		}
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(c.r, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = binary.BigEndian.Uint64(ext[:])
		if length>>63 != 0 || length <= 0xFFFF {
			return false, 0, nil, fmt.Errorf("%w: a bad 64-bit length", ErrProtocol)
		}
	}
	if op >= 0x8 && (!fin || length > 125) {
		return false, 0, nil, fmt.Errorf("%w: a fragmented or long control frame", ErrProtocol)
	}
	if length > uint64(c.max) {
		return false, 0, nil, fmt.Errorf("%w: a frame over %d bytes", ErrProtocol, c.max)
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(c.r, payload); err != nil {
		return false, 0, nil, err
	}
	return fin, op, payload, nil
}

// Write sends p as one binary message.
func (c *Conn) Write(p []byte) (int, error) {
	if err := c.writeFrame(opBinary, p); err != nil {
		return 0, err
	}
	return len(p), nil
}

// writeFrame sends one final frame, masked, as a client must.
func (c *Conn) writeFrame(op byte, payload []byte) error {
	frame := make([]byte, 0, 14+len(payload))
	frame = append(frame, 0x80|op)
	switch n := len(payload); {
	case n < 126:
		frame = append(frame, 0x80|byte(n))
	case n <= 0xFFFF:
		frame = append(frame, 0x80|126, byte(n>>8), byte(n))
	default:
		frame = append(frame, 0x80|127)
		frame = binary.BigEndian.AppendUint64(frame, uint64(n))
	}
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	frame = append(frame, mask[:]...)
	start := len(frame)
	frame = append(frame, payload...)
	maskBytes(frame[start:], mask)
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if c.closed {
		return net.ErrClosed
	}
	_, err := c.conn.Write(frame)
	return err
}

func maskBytes(b []byte, mask [4]byte) {
	for i := range b {
		b[i] ^= mask[i%4]
	}
}

// SetDeadline sets the connection's read and write deadline.
func (c *Conn) SetDeadline(t time.Time) error { return c.conn.SetDeadline(t) }

// Close sends a normal close (1000), when it can, and closes the
// connection.
func (c *Conn) Close() error { return c.close([]byte{0x03, 0xE8}) }

// close sends a close frame with code (best effort, and not for long: the
// network may be what failed), once, and closes the connection.
func (c *Conn) close(code []byte) error {
	c.wmu.Lock()
	if c.closed {
		c.wmu.Unlock()
		return nil
	}
	c.wmu.Unlock()
	c.conn.SetWriteDeadline(time.Now().Add(time.Second))
	c.writeFrame(opClose, code)
	c.wmu.Lock()
	c.closed = true
	c.wmu.Unlock()
	return c.conn.Close()
}
