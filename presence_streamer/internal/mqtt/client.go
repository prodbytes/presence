package mqtt

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"time"
)

// MaxPacket is the largest packet taken by default: AWS IoT's messages are
// at most 128 KB.
const MaxPacket = 256 << 10

// ErrSubscriptionRefused is a SUBACK's failure (0x80): the broker (its
// policy) refused the topic filter.
var ErrSubscriptionRefused = errors.New("mqtt: subscription refused")

// ErrKeepAlive is a broker silent past the keep-alive.
var ErrKeepAlive = errors.New("mqtt: no answer within the keep-alive")

// Options are a connection's.
type Options struct {
	ClientID string
	// Clean asks for a clean session (no persistent one).
	Clean bool
	// KeepAlive is the keep-alive: a PINGREQ goes every three quarters of
	// it, and a broker silent for one and a half of it drops the
	// connection. 0 is 60 s.
	KeepAlive time.Duration
	// MaxPacket is the largest packet taken; 0 is [MaxPacket].
	MaxPacket int
	// Buffer is how many received messages wait to be taken (Messages);
	// more are dropped (Dropped). 0 is 64.
	Buffer int
}

// Client is a connected MQTT client.
type Client struct {
	conn io.ReadWriteCloser
	r    *bufio.Reader
	o    Options

	// SessionPresent is the CONNACK's flag: the broker had a session for
	// this client ID.
	SessionPresent bool

	wmu sync.Mutex

	mu     sync.Mutex
	nextID uint16
	subs   map[uint16]chan byte

	messages chan Message
	dropped  atomic.Int64
	lastRead atomic.Int64

	done     chan struct{}
	failOnce sync.Once
	err      error
}

// Connect sends CONNECT over conn and waits for the CONNACK (until ctx
// ends, which closes conn). On success the client reads and keeps the
// connection alive until it drops or is closed; conn is closed on failure.
func Connect(ctx context.Context, conn io.ReadWriteCloser, o Options) (*Client, error) {
	if o.KeepAlive <= 0 {
		o.KeepAlive = 60 * time.Second
	}
	if o.MaxPacket <= 0 {
		o.MaxPacket = MaxPacket
	}
	if o.Buffer <= 0 {
		o.Buffer = 64
	}
	if !validString(o.ClientID) || o.ClientID == "" {
		conn.Close()
		return nil, errors.New("mqtt: a bad client ID")
	}
	keepAlive := o.KeepAlive / time.Second
	if keepAlive < 1 {
		keepAlive = 1
	}
	c := &Client{
		conn: conn, r: bufio.NewReader(conn), o: o,
		subs: map[uint16]chan byte{}, messages: make(chan Message, o.Buffer), done: make(chan struct{}),
	}
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	if err := c.write(connectPacket(o.ClientID, o.Clean, uint16(min(keepAlive, 0xFFFF)))); err != nil {
		conn.Close()
		return nil, contextOr(ctx, err)
	}
	p, err := readPacket(c.r, 16)
	if err == nil {
		c.SessionPresent, err = parseConnack(p)
	}
	if err != nil {
		conn.Close()
		return nil, contextOr(ctx, err)
	}
	if !stop() {
		// ctx ended as it connected: closed already.
		return nil, ctx.Err()
	}
	c.lastRead.Store(time.Now().UnixNano())
	go c.readLoop()
	go c.keepAlive()
	return c, nil
}

// contextOr is ctx's error once it ended (it closed the connection), else
// err.
func contextOr(ctx context.Context, err error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

func (c *Client) write(b []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err := c.conn.Write(b)
	return err
}

// fail ends the connection with err (the first one).
func (c *Client) fail(err error) {
	c.failOnce.Do(func() {
		c.err = err
		c.conn.Close()
		close(c.done)
	})
}

// Done is closed once the connection has ended (dropped or closed).
func (c *Client) Done() <-chan struct{} { return c.done }

// Err is why it ended, once Done is closed.
func (c *Client) Err() error {
	select {
	case <-c.done:
		return c.err
	default:
		return nil
	}
}

// Messages are the PUBLISHes received, in order.
func (c *Client) Messages() <-chan Message { return c.messages }

// Dropped is how many received messages were dropped because Messages
// was full.
func (c *Client) Dropped() int64 { return c.dropped.Load() }

func (c *Client) readLoop() {
	for {
		p, err := readPacket(c.r, c.o.MaxPacket)
		if err != nil {
			c.fail(err)
			return
		}
		c.lastRead.Store(time.Now().UnixNano())
		switch p.kind {
		case typePublish:
			m, err := parsePublish(p)
			if err != nil {
				c.fail(err)
				return
			}
			if m.QoS == 1 {
				if err := c.write(pubackPacket(m.ID)); err != nil {
					c.fail(err)
					return
				}
			}
			select {
			case c.messages <- m:
			default:
				c.dropped.Add(1)
			}
		case typeSuback:
			id, code, err := parseSuback(p)
			if err != nil {
				c.fail(err)
				return
			}
			c.mu.Lock()
			ch := c.subs[id]
			delete(c.subs, id)
			c.mu.Unlock()
			if ch != nil {
				ch <- code
			}
		case typePuback, typeUnsuback:
			if p.flags != 0 || len(p.body) != 2 {
				c.fail(fmt.Errorf("%w: a bad acknowledgement", ErrMalformed))
				return
			}
		case typePingresp:
			if p.flags != 0 || len(p.body) != 0 {
				c.fail(fmt.Errorf("%w: a bad PINGRESP", ErrMalformed))
				return
			}
		default:
			c.fail(fmt.Errorf("%w: unexpected packet type %d", ErrMalformed, p.kind))
			return
		}
	}
}

// keepAlive pings every three quarters of the keep-alive, and drops a
// connection silent for one and a half of it.
func (c *Client) keepAlive() {
	every := c.o.KeepAlive * 3 / 4
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-c.done:
			return
		case <-t.C:
		}
		if time.Since(time.Unix(0, c.lastRead.Load())) > c.o.KeepAlive*3/2 {
			c.fail(ErrKeepAlive)
			return
		}
		if err := c.write(pingreqPacket); err != nil {
			c.fail(err)
			return
		}
	}
}

// id is the next packet ID (never 0). Callers hold mu.
func (c *Client) id() uint16 {
	c.nextID++
	if c.nextID == 0 {
		c.nextID = 1
	}
	return c.nextID
}

// Subscribe subscribes to filter at qos and waits for the SUBACK: the QoS
// granted, or [ErrSubscriptionRefused].
func (c *Client) Subscribe(ctx context.Context, filter string, qos byte) (byte, error) {
	if !validString(filter) || filter == "" || qos > 1 {
		return 0, errors.New("mqtt: a bad subscription")
	}
	ch := make(chan byte, 1)
	c.mu.Lock()
	id := c.id()
	c.subs[id] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.subs, id)
		c.mu.Unlock()
	}()
	if err := c.write(subscribePacket(id, filter, qos)); err != nil {
		c.fail(err)
		return 0, err
	}
	select {
	case code := <-ch:
		if code == 0x80 {
			return 0, ErrSubscriptionRefused
		}
		return code, nil
	case <-c.done:
		return 0, c.err
	case <-ctx.Done():
		return 0, ctx.Err()
	}
}

// Publish sends payload on topic at qos (0 or 1), without waiting for the
// broker's PUBACK (as the app's client): one sent just before a drop may be
// lost.
func (c *Client) Publish(topic string, payload []byte, qos byte, retain bool) error {
	if !validTopic(topic) || qos > 1 {
		return errors.New("mqtt: a bad publish")
	}
	m := Message{Topic: topic, Payload: payload, QoS: qos, Retain: retain}
	if qos == 1 {
		c.mu.Lock()
		m.ID = c.id()
		c.mu.Unlock()
	}
	b := publishPacket(m)
	if len(b) > maxRemainingLen {
		return errors.New("mqtt: a message too big")
	}
	if err := c.write(b); err != nil {
		c.fail(err)
		return err
	}
	return nil
}

// Close sends DISCONNECT (best effort) and closes the connection.
func (c *Client) Close() error {
	first := false
	c.failOnce.Do(func() {
		first = true
		c.err = ErrClosed
		close(c.done)
	})
	if !first {
		return nil
	}
	// Not for long: the network may be what failed.
	if d, ok := c.conn.(interface{ SetDeadline(time.Time) error }); ok {
		d.SetDeadline(time.Now().Add(time.Second))
	}
	c.write(disconnectPacket)
	return c.conn.Close()
}

// ErrClosed is a connection closed here (Close).
var ErrClosed = errors.New("mqtt: closed")
