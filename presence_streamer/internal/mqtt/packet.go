// Package mqtt is the subset of MQTT 3.1.1 live sync uses, as a client:
// CONNECT/CONNACK, SUBSCRIBE/SUBACK, PUBLISH at QoS 0 and 1 (with PUBACK),
// PINGREQ/PINGRESP and DISCONNECT, over any byte stream (a WebSocket, see
// the ws package). Everything the broker sends is bounded and checked.
package mqtt

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"
)

// Packet types (the fixed header's high nibble).
const (
	typeConnect     = 1
	typeConnack     = 2
	typePublish     = 3
	typePuback      = 4
	typeSubscribe   = 8
	typeSuback      = 9
	typeUnsuback    = 11
	typePingreq     = 12
	typePingresp    = 13
	typeDisconnect  = 14
	maxRemainingLen = 268435455
)

// ErrMalformed is a packet that breaks MQTT 3.1.1, or is bigger than taken.
var ErrMalformed = errors.New("mqtt: malformed packet")

// packet is a received packet: its fixed header's type and flags, and the
// rest.
type packet struct {
	kind  byte
	flags byte
	body  []byte
}

// appendLength appends MQTT's variable-length encoding of n (at most four
// bytes, n <= 268,435,455).
func appendLength(b []byte, n int) []byte {
	for {
		d := byte(n % 128)
		n /= 128
		if n > 0 {
			d |= 0x80
		}
		b = append(b, d)
		if n == 0 {
			return b
		}
	}
}

// readLength reads a remaining length: at most four bytes.
func readLength(r io.ByteReader) (int, error) {
	n, shift := 0, 0
	for i := 0; i < 4; i++ {
		d, err := r.ReadByte()
		if err != nil {
			return 0, err
		}
		n |= int(d&0x7F) << shift
		if d&0x80 == 0 {
			return n, nil
		}
		shift += 7
	}
	return 0, fmt.Errorf("%w: a remaining length over four bytes", ErrMalformed)
}

// readPacket reads one packet of at most max bytes (its remaining length).
func readPacket(r *bufio.Reader, max int) (packet, error) {
	head, err := r.ReadByte()
	if err != nil {
		return packet{}, err
	}
	n, err := readLength(r)
	if err != nil {
		return packet{}, err
	}
	if n > max {
		return packet{}, fmt.Errorf("%w: %d bytes, over %d", ErrMalformed, n, max)
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(r, body); err != nil {
		if err == io.EOF {
			err = io.ErrUnexpectedEOF
		}
		return packet{}, err
	}
	return packet{kind: head >> 4, flags: head & 0x0F, body: body}, nil
}

// encode is a packet with its fixed header.
func encode(kind, flags byte, body []byte) []byte {
	b := appendLength([]byte{kind<<4 | flags}, len(body))
	return append(b, body...)
}

func appendString(b []byte, s string) []byte {
	b = binary.BigEndian.AppendUint16(b, uint16(len(s)))
	return append(b, s...)
}

// validString says whether s can be an MQTT UTF-8 string: at most 65,535
// bytes, valid UTF-8, no U+0000.
func validString(s string) bool {
	if len(s) > 0xFFFF || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r == 0 {
			return false
		}
	}
	return true
}

// validTopic says whether s is a topic name one may publish to (no
// wildcards).
func validTopic(s string) bool {
	if s == "" || !validString(s) {
		return false
	}
	for _, r := range s {
		if r == '+' || r == '#' {
			return false
		}
	}
	return true
}

// connectPacket is CONNECT with MQTT 3.1.1 (level 4), a clean session or
// not, the keep-alive in seconds and the client ID; no will, user or
// password (AWS IoT's WebSocket is authorized by its signed URL).
func connectPacket(clientID string, clean bool, keepAlive uint16) []byte {
	body := appendString(nil, "MQTT")
	flags := byte(0)
	if clean {
		flags |= 0x02
	}
	body = append(body, 4, flags)
	body = binary.BigEndian.AppendUint16(body, keepAlive)
	body = appendString(body, clientID)
	return encode(typeConnect, 0, body)
}

// connackReturns are CONNACK's refusals, by code.
var connackReturns = map[byte]string{
	1: "unacceptable protocol version",
	2: "identifier rejected",
	3: "server unavailable",
	4: "bad user name or password",
	5: "not authorized",
}

// RefusedError is a CONNACK that refused the connection.
type RefusedError struct{ Code byte }

func (e RefusedError) Error() string {
	if why, ok := connackReturns[e.Code]; ok {
		return "mqtt: connection refused: " + why
	}
	return fmt.Sprintf("mqtt: connection refused (%d)", e.Code)
}

// parseConnack is a CONNACK's session-present flag, or why it refused.
func parseConnack(p packet) (bool, error) {
	if p.kind != typeConnack || p.flags != 0 || len(p.body) != 2 || p.body[0]&0xFE != 0 {
		return false, fmt.Errorf("%w: expected a CONNACK", ErrMalformed)
	}
	if p.body[1] != 0 {
		return false, RefusedError{Code: p.body[1]}
	}
	return p.body[0]&1 == 1, nil
}

// subscribePacket subscribes to one topic filter at qos.
func subscribePacket(id uint16, filter string, qos byte) []byte {
	body := binary.BigEndian.AppendUint16(nil, id)
	body = appendString(body, filter)
	body = append(body, qos)
	return encode(typeSubscribe, 0x2, body)
}

// parseSuback is a SUBACK's packet ID and its one return code.
func parseSuback(p packet) (uint16, byte, error) {
	if p.flags != 0 || len(p.body) != 3 {
		return 0, 0, fmt.Errorf("%w: a SUBACK of %d bytes", ErrMalformed, len(p.body))
	}
	code := p.body[2]
	if code > 2 && code != 0x80 {
		return 0, 0, fmt.Errorf("%w: SUBACK return code %d", ErrMalformed, code)
	}
	return binary.BigEndian.Uint16(p.body), code, nil
}

// Message is a PUBLISH: its topic and payload, QoS and retain flag.
type Message struct {
	Topic   string
	Payload []byte
	QoS     byte
	Retain  bool
	// ID is a QoS 1 message's packet ID.
	ID uint16
}

// publishPacket publishes m (QoS 0 or 1; m.ID for QoS 1).
func publishPacket(m Message) []byte {
	flags := m.QoS << 1
	if m.Retain {
		flags |= 1
	}
	body := appendString(nil, m.Topic)
	if m.QoS > 0 {
		body = binary.BigEndian.AppendUint16(body, m.ID)
	}
	body = append(body, m.Payload...)
	return encode(typePublish, flags, body)
}

// parsePublish reads a received PUBLISH: QoS 0 or 1 (2 is refused: nothing
// subscribes at it), a valid topic name, a packet ID that isn't 0 at QoS 1.
func parsePublish(p packet) (Message, error) {
	qos := (p.flags >> 1) & 3
	if qos > 1 {
		return Message{}, fmt.Errorf("%w: a PUBLISH at QoS %d", ErrMalformed, qos)
	}
	if qos == 0 && p.flags&0x08 != 0 {
		return Message{}, fmt.Errorf("%w: DUP at QoS 0", ErrMalformed)
	}
	b := p.body
	if len(b) < 2 {
		return Message{}, fmt.Errorf("%w: a short PUBLISH", ErrMalformed)
	}
	n := int(binary.BigEndian.Uint16(b))
	b = b[2:]
	if len(b) < n {
		return Message{}, fmt.Errorf("%w: a PUBLISH topic past its end", ErrMalformed)
	}
	topic := string(b[:n])
	b = b[n:]
	if !validTopic(topic) {
		return Message{}, fmt.Errorf("%w: a bad topic name", ErrMalformed)
	}
	m := Message{Topic: topic, QoS: qos, Retain: p.flags&1 == 1}
	if qos == 1 {
		if len(b) < 2 {
			return Message{}, fmt.Errorf("%w: a PUBLISH without its packet ID", ErrMalformed)
		}
		m.ID = binary.BigEndian.Uint16(b)
		if m.ID == 0 {
			return Message{}, fmt.Errorf("%w: packet ID 0", ErrMalformed)
		}
		b = b[2:]
	}
	m.Payload = b
	return m, nil
}

func pubackPacket(id uint16) []byte {
	return encode(typePuback, 0, binary.BigEndian.AppendUint16(nil, id))
}

var (
	pingreqPacket    = []byte{typePingreq << 4, 0}
	disconnectPacket = []byte{typeDisconnect << 4, 0}
)
