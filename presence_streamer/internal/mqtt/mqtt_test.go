package mqtt

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/mqtt/mqtttest"
)

func TestRemainingLength(t *testing.T) {
	for _, tc := range []struct {
		n    int
		want []byte
	}{
		{0, []byte{0x00}},
		{127, []byte{0x7F}},
		{128, []byte{0x80, 0x01}},
		{16383, []byte{0xFF, 0x7F}},
		{16384, []byte{0x80, 0x80, 0x01}},
		{2097151, []byte{0xFF, 0xFF, 0x7F}},
		{2097152, []byte{0x80, 0x80, 0x80, 0x01}},
		{268435455, []byte{0xFF, 0xFF, 0xFF, 0x7F}},
	} {
		got := appendLength(nil, tc.n)
		if !bytes.Equal(got, tc.want) {
			t.Errorf("appendLength(%d) = %x, want %x", tc.n, got, tc.want)
		}
		n, err := readLength(bytes.NewReader(tc.want))
		if err != nil || n != tc.n {
			t.Errorf("readLength(%x) = %d, %v", tc.want, n, err)
		}
	}
	if _, err := readLength(bytes.NewReader([]byte{0xFF, 0xFF, 0xFF, 0xFF, 0x01})); !errors.Is(err, ErrMalformed) {
		t.Errorf("five bytes: %v", err)
	}
	if _, err := readLength(bytes.NewReader([]byte{0x80})); err == nil {
		t.Error("a cut length was taken")
	}
}

func TestReadPacketBounds(t *testing.T) {
	// 300 bytes announced, 256 taken.
	r := bufio.NewReader(bytes.NewReader(append([]byte{0x30, 0xAC, 0x02}, make([]byte, 300)...)))
	if _, err := readPacket(r, 256); !errors.Is(err, ErrMalformed) {
		t.Fatalf("oversized: %v", err)
	}
	// Cut short.
	r = bufio.NewReader(bytes.NewReader([]byte{0x30, 0x05, 1, 2}))
	if _, err := readPacket(r, 256); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("short: %v", err)
	}
}

func TestPackets(t *testing.T) {
	got := connectPacket("id", true, 60)
	want := []byte{0x10, 14, 0, 4, 'M', 'Q', 'T', 'T', 4, 0x02, 0, 60, 0, 2, 'i', 'd'}
	if !bytes.Equal(got, want) {
		t.Errorf("CONNECT %x, want %x", got, want)
	}
	if got := connectPacket("id", false, 60); got[9] != 0 {
		t.Errorf("persistent CONNECT flags %x", got[9])
	}
	got = subscribePacket(7, "a/b", 1)
	want = []byte{0x82, 8, 0, 7, 0, 3, 'a', '/', 'b', 1}
	if !bytes.Equal(got, want) {
		t.Errorf("SUBSCRIBE %x, want %x", got, want)
	}
	got = publishPacket(Message{Topic: "t", Payload: []byte("hi"), QoS: 1, ID: 5})
	want = []byte{0x32, 7, 0, 1, 't', 0, 5, 'h', 'i'}
	if !bytes.Equal(got, want) {
		t.Errorf("PUBLISH %x, want %x", got, want)
	}
	got = publishPacket(Message{Topic: "t", Payload: []byte("hi"), Retain: true})
	want = []byte{0x31, 5, 0, 1, 't', 'h', 'i'}
	if !bytes.Equal(got, want) {
		t.Errorf("PUBLISH QoS 0 %x, want %x", got, want)
	}
	if got := pubackPacket(0x0102); !bytes.Equal(got, []byte{0x40, 2, 1, 2}) {
		t.Errorf("PUBACK %x", got)
	}
}

func TestParsePublish(t *testing.T) {
	ok := []struct {
		p    packet
		want Message
	}{
		{packet{typePublish, 0x2, []byte{0, 1, 't', 0, 9, 'x'}}, Message{Topic: "t", Payload: []byte("x"), QoS: 1, ID: 9}},
		{packet{typePublish, 0x1, []byte{0, 1, 't'}}, Message{Topic: "t", Payload: []byte{}, Retain: true}},
		{packet{typePublish, 0xA, []byte{0, 1, 't', 0, 1}}, Message{Topic: "t", Payload: []byte{}, QoS: 1, ID: 1}},
	}
	for _, tc := range ok {
		m, err := parsePublish(tc.p)
		if err != nil || m.Topic != tc.want.Topic || !bytes.Equal(m.Payload, tc.want.Payload) || m.QoS != tc.want.QoS || m.ID != tc.want.ID || m.Retain != tc.want.Retain {
			t.Errorf("parsePublish(%v) = %+v, %v", tc.p, m, err)
		}
	}
	for name, p := range map[string]packet{
		"QoS 2":          {typePublish, 0x4, []byte{0, 1, 't', 0, 1}},
		"QoS 3":          {typePublish, 0x6, []byte{0, 1, 't', 0, 1}},
		"DUP at QoS 0":   {typePublish, 0x8, []byte{0, 1, 't'}},
		"short":          {typePublish, 0, []byte{0}},
		"topic past end": {typePublish, 0, []byte{0, 9, 't'}},
		"empty topic":    {typePublish, 0, []byte{0, 0}},
		"wildcard topic": {typePublish, 0, []byte{0, 1, '#'}},
		"bad UTF-8":      {typePublish, 0, []byte{0, 1, 0xFF}},
		"NUL in topic":   {typePublish, 0, []byte{0, 1, 0}},
		"no packet ID":   {typePublish, 0x2, []byte{0, 1, 't', 0}},
		"packet ID 0":    {typePublish, 0x2, []byte{0, 1, 't', 0, 0}},
	} {
		if _, err := parsePublish(p); !errors.Is(err, ErrMalformed) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestParseConnackAndSuback(t *testing.T) {
	if present, err := parseConnack(packet{typeConnack, 0, []byte{1, 0}}); err != nil || !present {
		t.Errorf("session present: %v %v", present, err)
	}
	var refused RefusedError
	if _, err := parseConnack(packet{typeConnack, 0, []byte{0, 5}}); !errors.As(err, &refused) || refused.Code != 5 {
		t.Errorf("refused: %v", err)
	}
	for _, p := range []packet{{typeConnack, 0, []byte{0}}, {typeConnack, 0, []byte{2, 0}}, {typePublish, 0, []byte{0, 0}}} {
		if _, err := parseConnack(p); !errors.Is(err, ErrMalformed) {
			t.Errorf("parseConnack(%v): %v", p, err)
		}
	}
	if id, code, err := parseSuback(packet{typeSuback, 0, []byte{0, 3, 0x80}}); err != nil || id != 3 || code != 0x80 {
		t.Errorf("suback: %d %d %v", id, code, err)
	}
	for _, p := range []packet{{typeSuback, 0, []byte{0, 3}}, {typeSuback, 0, []byte{0, 3, 3}}, {typeSuback, 1, []byte{0, 3, 0}}} {
		if _, _, err := parseSuback(p); !errors.Is(err, ErrMalformed) {
			t.Errorf("parseSuback(%v): %v", p, err)
		}
	}
}

// pair connects a client to a fake broker over an in-memory pipe.
func pair(t *testing.T, b *mqtttest.Broker, o Options) (*Client, *mqtttest.Session) {
	t.Helper()
	client, server := net.Pipe()
	go b.Serve(server)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Connect(ctx, client, o)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	select {
	case s := <-b.Sessions:
		return c, s
	case <-time.After(5 * time.Second):
		t.Fatal("no session")
	}
	return nil, nil
}

func TestClientSubscribePublishReceive(t *testing.T) {
	b := mqtttest.New()
	b.RefuseTopics["no"] = true
	c, s := pair(t, b, Options{ClientID: "us-east-1:x-dev-abc", Clean: true, KeepAlive: time.Minute})
	if s.ClientID != "us-east-1:x-dev-abc" || !s.Clean || s.KeepAlive != 60 {
		t.Fatalf("CONNECT: %+v", s)
	}
	ctx := context.Background()
	if qos, err := c.Subscribe(ctx, "a/b", 1); err != nil || qos != 1 {
		t.Fatalf("subscribe: %d %v", qos, err)
	}
	if _, err := c.Subscribe(ctx, "no", 1); !errors.Is(err, ErrSubscriptionRefused) {
		t.Fatalf("refused subscribe: %v", err)
	}
	if err := c.Publish("a/b", []byte("hello"), 1, false); err != nil {
		t.Fatal(err)
	}
	if m := <-s.Published; m.Topic != "a/b" || string(m.Payload) != "hello" || m.QoS != 1 {
		t.Fatalf("published %+v", m)
	}
	s.Send("a/b", []byte("back"), 1)
	s.Send("a/b", []byte("zero"), 0)
	for _, want := range []string{"back", "zero"} {
		select {
		case m := <-c.Messages():
			if string(m.Payload) != want {
				t.Fatalf("got %q, want %q", m.Payload, want)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("no message")
		}
	}
	c.Close()
	select {
	case <-s.Disconnected:
	case <-time.After(5 * time.Second):
		t.Fatal("no DISCONNECT")
	}
	if !errors.Is(c.Err(), ErrClosed) {
		t.Fatalf("err %v", c.Err())
	}
}

func TestClientRefused(t *testing.T) {
	b := mqtttest.New()
	b.Refuse = 5
	client, server := net.Pipe()
	go b.Serve(server)
	_, err := Connect(context.Background(), client, Options{ClientID: "x"})
	var refused RefusedError
	if !errors.As(err, &refused) || refused.Code != 5 {
		t.Fatalf("got %v", err)
	}
}

func TestClientConnectTimesOut(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	// The server reads the CONNECT and says nothing.
	go io.Copy(io.Discard, server)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if _, err := Connect(ctx, client, Options{ClientID: "x"}); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("got %v", err)
	}
}

func TestClientDropsOnMalformedPacket(t *testing.T) {
	c, s := pair(t, mqtttest.New(), Options{ClientID: "x"})
	// A PUBLISH at QoS 2.
	s.WriteRaw([]byte{0x34, 5, 0, 1, 't', 0, 1})
	select {
	case <-c.Done():
		if !errors.Is(c.Err(), ErrMalformed) {
			t.Fatalf("err %v", c.Err())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("still up")
	}
}

func TestClientDropsOversizedPacket(t *testing.T) {
	c, s := pair(t, mqtttest.New(), Options{ClientID: "x", MaxPacket: 64})
	s.Send("t", make([]byte, 100), 0)
	select {
	case <-c.Done():
		if !errors.Is(c.Err(), ErrMalformed) {
			t.Fatalf("err %v", c.Err())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("still up")
	}
}

func TestClientDropsWhenTheServerGoes(t *testing.T) {
	c, s := pair(t, mqtttest.New(), Options{ClientID: "x"})
	s.Close()
	select {
	case <-c.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("still up")
	}
}

func TestKeepAlive(t *testing.T) {
	// Answered: pings go, and it stays.
	c, s := pair(t, mqtttest.New(), Options{ClientID: "x", KeepAlive: 80 * time.Millisecond})
	for i := 0; i < 3; i++ {
		select {
		case <-s.Pings:
		case <-time.After(5 * time.Second):
			t.Fatal("no ping")
		}
	}
	if c.Err() != nil {
		t.Fatalf("dropped: %v", c.Err())
	}
	// Silent: dropped.
	b := mqtttest.New()
	b.Silent = true
	c, _ = pair(t, b, Options{ClientID: "x", KeepAlive: 80 * time.Millisecond})
	select {
	case <-c.Done():
		if !errors.Is(c.Err(), ErrKeepAlive) {
			t.Fatalf("err %v", c.Err())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a silent broker kept")
	}
}

func TestFullBufferDrops(t *testing.T) {
	c, s := pair(t, mqtttest.New(), Options{ClientID: "x", Buffer: 1})
	for i := 0; i < 3; i++ {
		s.Send("t", []byte{byte(i)}, 1)
	}
	deadline := time.Now().Add(5 * time.Second)
	for c.Dropped() < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if c.Dropped() != 2 {
		t.Fatalf("dropped %d", c.Dropped())
	}
	if m := <-c.Messages(); m.Payload[0] != 0 {
		t.Fatalf("kept %v", m.Payload)
	}
}

func TestBadArguments(t *testing.T) {
	c, _ := pair(t, mqtttest.New(), Options{ClientID: "x"})
	if err := c.Publish("a/#", nil, 1, false); err == nil {
		t.Error("published to a wildcard")
	}
	if err := c.Publish("a", nil, 2, false); err == nil {
		t.Error("published at QoS 2")
	}
	if _, err := c.Subscribe(context.Background(), "", 1); err == nil {
		t.Error("subscribed to nothing")
	}
	client, server := net.Pipe()
	defer server.Close()
	if _, err := Connect(context.Background(), client, Options{ClientID: ""}); err == nil {
		t.Error("an empty client ID")
	}
}
