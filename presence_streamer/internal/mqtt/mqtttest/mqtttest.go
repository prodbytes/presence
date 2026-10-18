// Package mqtttest is a fake MQTT 3.1.1 broker for tests, with its own
// small codec (so it checks the client's rather than sharing it): it
// takes one connection at a time, answers CONNECT, SUBSCRIBE, PUBLISH (QoS
// 1: PUBACK) and PINGREQ, and lets the test send messages and drop the
// connection.
package mqtttest

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
)

// Message is a PUBLISH.
type Message struct {
	Topic   string
	Payload []byte
	QoS     byte
	Retain  bool
}

// Broker answers connections as set.
type Broker struct {
	// Refuse is CONNACK's return code (0 accepts).
	Refuse byte
	// RefuseTopics are subscriptions refused (0x80).
	RefuseTopics map[string]bool
	// SessionPresent is CONNACK's flag.
	SessionPresent bool
	// Silent doesn't answer PINGREQs.
	Silent bool

	// Sessions gets each accepted connection.
	Sessions chan *Session
}

// New is a broker that accepts everything.
func New() *Broker {
	return &Broker{Sessions: make(chan *Session, 16), RefuseTopics: map[string]bool{}}
}

// Session is one connection.
type Session struct {
	ClientID  string
	Clean     bool
	KeepAlive uint16

	// Subscribed gets each topic filter subscribed to; Published each
	// message the client publishes; Pings a value per PINGREQ.
	Subscribed chan string
	Published  chan Message
	Pings      chan struct{}
	// Disconnected is closed at a DISCONNECT.
	Disconnected chan struct{}

	conn   io.ReadWriteCloser
	wmu    sync.Mutex
	nextID uint16
}

// Serve speaks MQTT on conn until it ends: the client goes, or Close.
func (b *Broker) Serve(conn io.ReadWriteCloser) error {
	defer conn.Close()
	r := bufio.NewReader(conn)
	kind, _, body, err := read(r)
	if err != nil {
		return err
	}
	if kind != 1 {
		return fmt.Errorf("first packet %d, not CONNECT", kind)
	}
	s := &Session{conn: conn, Subscribed: make(chan string, 16), Published: make(chan Message, 64),
		Pings: make(chan struct{}, 64), Disconnected: make(chan struct{})}
	name, rest, err := str(body)
	if err != nil || name != "MQTT" || len(rest) < 4 || rest[0] != 4 {
		return errors.New("not MQTT 3.1.1")
	}
	s.Clean = rest[1]&0x02 != 0
	s.KeepAlive = binary.BigEndian.Uint16(rest[2:])
	if s.ClientID, _, err = str(rest[4:]); err != nil {
		return err
	}
	present := byte(0)
	if b.SessionPresent && b.Refuse == 0 {
		present = 1
	}
	if err := s.write(2, 0, []byte{present, b.Refuse}); err != nil || b.Refuse != 0 {
		return err
	}
	b.Sessions <- s
	for {
		kind, flags, body, err := read(r)
		if err != nil {
			return err
		}
		switch kind {
		case 8: // SUBSCRIBE
			if flags != 2 || len(body) < 2 {
				return errors.New("bad SUBSCRIBE")
			}
			filter, rest, err := str(body[2:])
			if err != nil || len(rest) != 1 {
				return errors.New("bad SUBSCRIBE filter")
			}
			code := rest[0]
			if b.RefuseTopics[filter] {
				code = 0x80
			}
			if err := s.write(9, 0, []byte{body[0], body[1], code}); err != nil {
				return err
			}
			s.Subscribed <- filter
		case 3: // PUBLISH
			topic, rest, err := str(body)
			if err != nil {
				return err
			}
			m := Message{Topic: topic, QoS: (flags >> 1) & 3, Retain: flags&1 == 1}
			if m.QoS == 1 {
				if len(rest) < 2 {
					return errors.New("bad PUBLISH")
				}
				if err := s.write(4, 0, rest[:2]); err != nil {
					return err
				}
				rest = rest[2:]
			}
			m.Payload = rest
			s.Published <- m
		case 4: // PUBACK
		case 12: // PINGREQ
			s.Pings <- struct{}{}
			if !b.Silent {
				if err := s.write(13, 0, nil); err != nil {
					return err
				}
			}
		case 14: // DISCONNECT
			close(s.Disconnected)
			return nil
		default:
			return fmt.Errorf("unexpected packet %d", kind)
		}
	}
}

// Send publishes to the client.
func (s *Session) Send(topic string, payload []byte, qos byte) error {
	body := binary.BigEndian.AppendUint16(nil, uint16(len(topic)))
	body = append(body, topic...)
	if qos == 1 {
		s.wmu.Lock()
		s.nextID++
		id := s.nextID
		s.wmu.Unlock()
		body = binary.BigEndian.AppendUint16(body, id)
	}
	return s.write(3, qos<<1, append(body, payload...))
}

// WriteRaw sends bytes as they are.
func (s *Session) WriteRaw(b []byte) error {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	_, err := s.conn.Write(b)
	return err
}

// Close drops the connection.
func (s *Session) Close() error { return s.conn.Close() }

func (s *Session) write(kind, flags byte, body []byte) error {
	b := []byte{kind<<4 | flags}
	n := len(body)
	for {
		d := byte(n % 128)
		n /= 128
		if n > 0 {
			d |= 0x80
		}
		b = append(b, d)
		if n == 0 {
			break
		}
	}
	return s.WriteRaw(append(b, body...))
}

func read(r *bufio.Reader) (kind, flags byte, body []byte, err error) {
	head, err := r.ReadByte()
	if err != nil {
		return
	}
	n, shift := 0, 0
	for i := 0; ; i++ {
		if i == 4 {
			return 0, 0, nil, errors.New("long remaining length")
		}
		d, err := r.ReadByte()
		if err != nil {
			return 0, 0, nil, err
		}
		n |= int(d&0x7F) << shift
		shift += 7
		if d&0x80 == 0 {
			break
		}
	}
	if n > 1<<20 {
		return 0, 0, nil, errors.New("packet too big")
	}
	body = make([]byte, n)
	_, err = io.ReadFull(r, body)
	return head >> 4, head & 0x0F, body, err
}

func str(b []byte) (string, []byte, error) {
	if len(b) < 2 {
		return "", nil, errors.New("short string")
	}
	n := int(binary.BigEndian.Uint16(b))
	if len(b) < 2+n {
		return "", nil, errors.New("string past its end")
	}
	return string(b[2 : 2+n]), b[2+n:], nil
}
