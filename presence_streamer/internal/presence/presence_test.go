package presence

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestProfileAndCredentials(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/auth/profile", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer idt" {
			w.WriteHeader(401)
			return
		}
		w.Write([]byte(`{"profile":"automatic_paranoid_axolotl","shared":[],"accounts":[]}`))
	})
	mux.HandleFunc("POST /api/auth/credentials", func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		if string(body) != "able_adept_gadget" {
			t.Errorf("credentials body %q", body)
		}
		w.Write([]byte(`{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","deviceLimit":50,"devices":["able_adept_gadget"],"tier":"premium","bucket":"user-data-test"}`))
	})
	mux.HandleFunc("POST /cognito", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Amz-Target") != "AWSCognitoIdentityService.GetCredentialsForIdentity" {
			t.Errorf("target %q", r.Header.Get("X-Amz-Target"))
		}
		var req map[string]any
		json.NewDecoder(r.Body).Decode(&req)
		if req["IdentityId"] != "us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b" || req["Logins"].(map[string]any)["cognito-identity.amazonaws.com"] != "tok" {
			t.Errorf("cognito request %v", req)
		}
		w.Write([]byte(`{"IdentityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","Credentials":{"AccessKeyId":"AK","SecretKey":"SK","SessionToken":"ST","Expiration":1.7904372E9}}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	api := &API{BaseURL: srv.URL + "/", CognitoURL: srv.URL + "/cognito"}
	ctx := context.Background()

	profile, err := api.Profile(ctx, "idt")
	if err != nil || profile != "automatic_paranoid_axolotl" {
		t.Fatalf("profile %q, %v", profile, err)
	}
	if _, err := api.Profile(ctx, "bad"); err != ErrUnauthorized {
		t.Fatalf("bad token: %v", err)
	}
	c, err := api.Credentials(ctx, "idt", "able_adept_gadget")
	if err != nil || !c.Premium() || c.Bucket != "user-data-test" || c.IdentityID != "us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b" {
		t.Fatalf("credentials %+v, %v", c, err)
	}
	aws, err := api.AWSCredentials(ctx, c)
	if err != nil || aws.AccessKeyID != "AK" || aws.SessionToken != "ST" || aws.Expiration.Unix() != 1790437200 {
		t.Fatalf("aws %+v, %v", aws, err)
	}
}

func TestRefusesAnswersThatAreNotIDs(t *testing.T) {
	for _, answer := range []string{
		`{"identityId":"evil.com/#:x","token":"tok"}`,
		`{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","bucket":"b --config x"}`,
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(answer)) }))
		if _, err := (&API{BaseURL: srv.URL}).Credentials(context.Background(), "idt", "a_b_c"); err == nil {
			t.Errorf("took %s", answer)
		}
		srv.Close()
	}
}

func TestFree(t *testing.T) {
	if (Credentials{Tier: "free"}).Premium() || (Credentials{}).Premium() {
		t.Fatal("free counts as premium")
	}
}

func TestStreamCredentials(t *testing.T) {
	const key = "psk_0123456789abcdefghijABCDEFGHIJ_-0123456789"
	var asked []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		asked = append(asked, r.Method+" "+r.URL.Path+" "+string(body))
		if r.Header.Get("Authorization") != "Bearer "+key {
			w.WriteHeader(401)
			w.Write([]byte(`{"error":"that stream key isn't this device's"}`))
			return
		}
		w.Write([]byte(`{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","deviceLimit":50,"devices":["calm_quiet_otter"],"tier":"premium","bucket":"user-data-test","userId":"1234"}`))
	}))
	defer srv.Close()
	api := &API{BaseURL: srv.URL}
	ctx := context.Background()

	c, err := api.StreamCredentials(ctx, key, "automatic_paranoid_axolotl", "calm_quiet_otter")
	if err != nil || !c.Premium() || c.UserID != "1234" || c.Bucket != "user-data-test" {
		t.Fatalf("stream credentials %+v, %v", c, err)
	}
	if asked[0] != "POST /api/auth/stream/credentials automatic_paranoid_axolotl calm_quiet_otter" {
		t.Fatalf("asked %q", asked[0])
	}
	if _, err := api.StreamCredentials(ctx, "psk_wrong", "automatic_paranoid_axolotl", "calm_quiet_otter"); err != ErrKeyRefused {
		t.Fatalf("a wrong key: %v", err)
	}
}

func TestCredentialsTheAuthAPIGivesItself(t *testing.T) {
	// The local stack: no Cognito, the answer has them.
	api := &API{CognitoURL: "http://127.0.0.1:1/never"}
	aws, err := api.AWSCredentials(context.Background(), Credentials{
		IdentityID: "us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b",
		Local:      &cognitoCredentials{AccessKeyID: "ASIALOCAL", SecretKey: "s", SessionToken: "t", Expiration: 1790437200},
	})
	if err != nil || aws.AccessKeyID != "ASIALOCAL" || aws.Expiration.Unix() != 1790437200 {
		t.Fatalf("aws %+v, %v", aws, err)
	}
}
