package google

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func jwt(payload string) string {
	return "h." + base64.RawURLEncoding.EncodeToString([]byte(payload)) + ".s"
}

func fakeGoogle(t *testing.T, pending int, final string) (*Client, *int) {
	polls := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/device/code", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		if r.Form.Get("client_id") != "cid" || r.Form.Get("scope") != "openid email" {
			t.Errorf("device code request %v", r.Form)
		}
		w.Write([]byte(`{"device_code":"dc","user_code":"ABC-DEF","verification_url":"https://www.google.com/device","expires_in":1800,"interval":5}`))
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		r.ParseForm()
		if r.Form.Get("client_secret") != "secret" {
			t.Errorf("no client secret: %v", r.Form)
		}
		switch r.Form.Get("grant_type") {
		case "refresh_token":
			if r.Form.Get("refresh_token") != "rt" {
				w.WriteHeader(400)
				w.Write([]byte(`{"error":"invalid_grant"}`))
				return
			}
			w.Write([]byte(`{"id_token":"` + jwt(`{"sub":"42"}`) + `"}`))
		default:
			polls++
			if polls <= pending {
				w.WriteHeader(428)
				w.Write([]byte(`{"error":"authorization_pending"}`))
				return
			}
			if final != "" {
				w.WriteHeader(403)
				w.Write([]byte(`{"error":"` + final + `"}`))
				return
			}
			w.Write([]byte(`{"id_token":"` + jwt(`{"sub":"42","email":"a@b.c","exp":99}`) + `","refresh_token":"rt"}`))
		}
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return &Client{
		ID: "cid", Secret: "secret",
		Endpoints: Endpoints{DeviceCode: srv.URL + "/device/code", Token: srv.URL + "/token"},
		Sleep:     func(context.Context, time.Duration) error { return nil },
	}, &polls
}

func TestDeviceFlow(t *testing.T) {
	c, polls := fakeGoogle(t, 2, "")
	code, err := c.RequestCode(context.Background())
	if err != nil || code.UserCode != "ABC-DEF" {
		t.Fatalf("code %+v, %v", code, err)
	}
	tokens, err := c.Wait(context.Background(), code)
	if err != nil || tokens.RefreshToken != "rt" || *polls != 3 {
		t.Fatalf("tokens %+v after %d polls, %v", tokens, *polls, err)
	}
	claims, err := ClaimsOf(tokens.IDToken)
	if err != nil || claims.Subject != "42" || claims.Email != "a@b.c" || claims.Expiry != 99 {
		t.Fatalf("claims %+v, %v", claims, err)
	}
}

func TestDenied(t *testing.T) {
	c, _ := fakeGoogle(t, 1, "access_denied")
	if _, err := c.Wait(context.Background(), Code{DeviceCode: "dc", Interval: 5, ExpiresIn: 1800}); err != ErrDenied {
		t.Fatalf("got %v", err)
	}
}

func TestRefresh(t *testing.T) {
	c, _ := fakeGoogle(t, 0, "")
	id, err := c.Refresh(context.Background(), "rt")
	if err != nil {
		t.Fatal(err)
	}
	if claims, _ := ClaimsOf(id); claims.Subject != "42" {
		t.Fatalf("claims %+v", claims)
	}
	if _, err := c.Refresh(context.Background(), "revoked"); err != ErrRevoked {
		t.Fatalf("revoked refresh: %v", err)
	}
}
