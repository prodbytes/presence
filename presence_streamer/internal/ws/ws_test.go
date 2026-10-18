package ws

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/ws/wstest"
)

// serve runs handle for each WebSocket made to a TLS test server, and
// answers its URL (wss://) and a TLS configuration that trusts it.
func serve(t *testing.T, protocol string, handle func(*wstest.Conn)) (string, *tls.Config) {
	t.Helper()
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := wstest.Upgrade(w, r, protocol)
		if err != nil {
			return
		}
		defer c.Close()
		handle(c)
	}))
	t.Cleanup(srv.Close)
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	return "wss" + strings.TrimPrefix(srv.URL, "https") + "/mqtt?X-Amz-Signature=secret", &tls.Config{RootCAs: pool}
}

func dial(t *testing.T, url string, cfg *tls.Config) *Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, err := Dial(ctx, url, Options{Subprotocol: "mqtt", TLS: cfg, MaxMessage: 1024})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func TestEchoMaskedBothWays(t *testing.T) {
	got := make(chan []byte, 1)
	url, cfg := serve(t, "mqtt", func(c *wstest.Conn) {
		fin, op, payload, masked, err := c.ReadFrame()
		if err != nil || !fin || op != 0x2 || !masked {
			t.Errorf("frame: fin %v op %d masked %v err %v", fin, op, masked, err)
		}
		got <- payload
		c.Write(payload)
		c.ReadFrame()
	})
	c := dial(t, url, cfg)
	// 200 bytes: the 16-bit length.
	msg := bytes.Repeat([]byte("ab"), 100)
	if _, err := c.Write(msg); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(<-got, msg) {
		t.Fatal("the server didn't get the message unmasked")
	}
	back := make([]byte, len(msg))
	if _, err := io.ReadFull(c, back); err != nil || !bytes.Equal(back, msg) {
		t.Fatalf("echo: %v", err)
	}
}

func TestFragmentsAndControlFrames(t *testing.T) {
	pong := make(chan []byte, 1)
	url, cfg := serve(t, "mqtt", func(c *wstest.Conn) {
		c.WriteFrame(false, 0x2, []byte("hel"))
		// A ping between fragments is answered, and the message goes on.
		c.WriteFrame(true, 0x9, []byte("p1"))
		c.WriteFrame(false, 0x0, []byte("lo "))
		c.WriteFrame(true, 0x0, []byte("world"))
		c.WriteFrame(true, 0xA, []byte("unasked pong"))
		c.WriteFrame(true, 0x2, nil)
		c.WriteFrame(true, 0x2, []byte("!"))
		_, op, payload, masked, _ := c.ReadFrame()
		if op == 0xA && masked {
			pong <- payload
		}
		c.WriteFrame(true, 0x8, []byte{0x03, 0xE8})
		c.ReadFrame()
	})
	c := dial(t, url, cfg)
	all, err := io.ReadAll(c)
	if err != nil {
		t.Fatal(err)
	}
	if string(all) != "hello world!" {
		t.Fatalf("got %q", all)
	}
	select {
	case p := <-pong:
		if string(p) != "p1" {
			t.Fatalf("pong %q", p)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("no pong")
	}
}

func TestRefusesBadFrames(t *testing.T) {
	for name, raw := range map[string][]byte{
		"text":                     {0x81, 0x01, 'x'},
		"masked from the server":   {0x82, 0x81, 1, 2, 3, 4, 'x'},
		"reserved bits":            {0xC2, 0x01, 'x'},
		"continuation first":       {0x80, 0x01, 'x'},
		"unknown opcode":           {0x83, 0x01, 'x'},
		"long control frame":       append([]byte{0x89, 126, 0, 126}, make([]byte, 126)...),
		"fragmented control":       {0x09, 0x00},
		"oversized frame":          append([]byte{0x82, 126, 0x04, 0x01}, make([]byte, 1025)...),
		"64-bit length, too big":   {0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0},
		"16-bit length, too short": {0x82, 126, 0, 5, 'a', 'b', 'c', 'd', 'e'},
		"new message inside one":   {0x02, 0x01, 'a', 0x82, 0x01, 'b'},
	} {
		t.Run(name, func(t *testing.T) {
			url, cfg := serve(t, "mqtt", func(c *wstest.Conn) {
				c.WriteRaw(raw)
				c.ReadFrame()
			})
			c := dial(t, url, cfg)
			_, err := c.Read(make([]byte, 8))
			if !errors.Is(err, ErrProtocol) {
				t.Fatalf("got %v, want a protocol error", err)
			}
		})
	}
}

func TestOversizedMessageAcrossFragments(t *testing.T) {
	url, cfg := serve(t, "mqtt", func(c *wstest.Conn) {
		for i := 0; i < 3; i++ {
			c.WriteFrame(false, map[bool]byte{true: 0x2, false: 0x0}[i == 0], make([]byte, 500))
		}
		c.ReadFrame()
	})
	c := dial(t, url, cfg)
	if _, err := c.Read(make([]byte, 8)); !errors.Is(err, ErrProtocol) {
		t.Fatalf("got %v", err)
	}
}

func TestHandshakeRefusals(t *testing.T) {
	ctx := context.Background()
	t.Run("not upgraded", func(t *testing.T) {
		srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.Error(w, "Forbidden: secret detail", http.StatusForbidden)
		}))
		defer srv.Close()
		pool := x509.NewCertPool()
		pool.AddCert(srv.Certificate())
		url := "wss" + strings.TrimPrefix(srv.URL, "https") + "/mqtt?X-Amz-Security-Token=TOKEN"
		_, err := Dial(ctx, url, Options{Subprotocol: "mqtt", TLS: &tls.Config{RootCAs: pool}})
		if err == nil || !strings.Contains(err.Error(), "403") {
			t.Fatalf("got %v", err)
		}
		// Neither the URL's query nor the body is quoted.
		if strings.Contains(err.Error(), "TOKEN") || strings.Contains(err.Error(), "secret") {
			t.Fatalf("leaks: %v", err)
		}
	})
	t.Run("untrusted certificate", func(t *testing.T) {
		url, _ := serve(t, "mqtt", func(c *wstest.Conn) {})
		if _, err := Dial(ctx, url, Options{Subprotocol: "mqtt"}); err == nil {
			t.Fatal("a self-signed server was trusted")
		}
	})
	t.Run("another subprotocol", func(t *testing.T) {
		url, cfg := serve(t, "mqtt", func(c *wstest.Conn) {})
		if _, err := Dial(ctx, url, Options{Subprotocol: "other", TLS: cfg}); err != nil {
			// The server says none: that's accepted.
			t.Fatal(err)
		}
	})
	t.Run("hung server", func(t *testing.T) {
		srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			time.Sleep(3 * time.Second)
		}))
		defer srv.Close()
		pool := x509.NewCertPool()
		pool.AddCert(srv.Certificate())
		ctx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
		defer cancel()
		start := time.Now()
		_, err := Dial(ctx, "wss"+strings.TrimPrefix(srv.URL, "https")+"/mqtt", Options{TLS: &tls.Config{RootCAs: pool}})
		if err == nil || time.Since(start) > 2*time.Second {
			t.Fatalf("got %v after %s", err, time.Since(start))
		}
	})
	t.Run("bad scheme", func(t *testing.T) {
		if _, err := Dial(ctx, "https://example.com/mqtt", Options{}); err == nil {
			t.Fatal("https taken")
		}
	})
}

func TestLongHandshakeRefused(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, _ := http.NewResponseController(w).Hijack()
		defer conn.Close()
		io.WriteString(conn, "HTTP/1.1 101 Switching Protocols\r\nX: "+strings.Repeat("a", 64<<10)+"\r\n\r\n")
	}))
	defer srv.Close()
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	_, err := Dial(context.Background(), "wss"+strings.TrimPrefix(srv.URL, "https")+"/mqtt", Options{TLS: &tls.Config{RootCAs: pool}})
	if err == nil {
		t.Fatal("a 64 KB handshake was taken")
	}
}

func TestMask(t *testing.T) {
	b := []byte{1, 2, 3, 4, 5}
	maskBytes(b, [4]byte{1, 1, 1, 1})
	if !bytes.Equal(b, []byte{0, 3, 2, 5, 4}) {
		t.Fatalf("%v", b)
	}
}
