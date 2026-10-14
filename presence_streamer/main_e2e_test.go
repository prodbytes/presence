package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/google"
	"github.com/prodbytes/presence/presence_streamer/internal/presence"
	"github.com/prodbytes/presence/presence_streamer/internal/seal"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/state"
)

// TestEndToEnd streams a video (10 s with no one, then 10 s with a
// person) through the real recorder, ffmpeg, detector and rclone, into
// rclone's own S3 server, with Google and the auth API faked. It needs
// ffmpeg, rclone, python3 with OpenCV and the models:
//
//	PRESENCE_STREAMER_E2E=1 PRESENCE_STREAMER_MODELS=<dir with yolov4-tiny.*> \
//	  PRESENCE_STREAMER_PYTHON=<python3 with cv2> PRESENCE_STREAMER_PERSON=<person.jpg> go test -run EndToEnd -v .
func TestEndToEnd(t *testing.T) {
	if os.Getenv("PRESENCE_STREAMER_E2E") != "1" {
		t.Skip("set PRESENCE_STREAMER_E2E=1")
	}
	person := os.Getenv("PRESENCE_STREAMER_PERSON")
	tmp := t.TempDir()
	// On a Pi: PRESENCE_STREAMER_E2E_CAMERA=1 records its real camera (any
	// source settings from PRESENCE_STREAMER_*), and
	// PRESENCE_STREAMER_DETECTION=cloud leaves chunks and jobs in ingest for
	// the cloud detector; PRESENCE_STREAMER_E2E_S3 keeps the bucket there.
	camera := os.Getenv("PRESENCE_STREAMER_E2E_CAMERA") == "1"
	cloud := os.Getenv("PRESENCE_STREAMER_DETECTION") == "cloud"

	// The camera: a gray picture, then the person, 10 s each.
	video := filepath.Join(tmp, "camera.mp4")
	if camera {
		// Its own.
	} else if out, err := exec.Command("ffmpeg", "-loglevel", "error",
		"-f", "lavfi", "-t", "10", "-i", "color=gray:s=1280x720:r=10",
		"-loop", "1", "-t", "10", "-r", "10", "-i", person,
		"-filter_complex", "[1:v]scale=1280:720,setsar=1[p];[0:v][p]concat=n=2:v=1[v]", "-map", "[v]",
		"-c:v", "libx264", "-pix_fmt", "yuv420p", video).CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}

	// The bucket.
	root := filepath.Join(tmp, "s3")
	if keep := os.Getenv("PRESENCE_STREAMER_E2E_S3"); keep != "" {
		root = keep
	}
	os.MkdirAll(filepath.Join(root, "bucket"), 0o755)
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	// The server may be another rclone than the streamer's (RCLONE_SERVER):
	// serve s3 came in rclone 1.65, newer than some distributions' rclone.
	serverBin := os.Getenv("RCLONE_SERVER")
	if serverBin == "" {
		serverBin = env("RCLONE", "rclone")
	}
	server := exec.Command(serverBin, "serve", "s3", root, "--addr", addr, "--config", "/dev/null", "-q")
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	defer server.Process.Kill()
	time.Sleep(time.Second)

	// Google, the auth API and Cognito.
	mux := http.NewServeMux()
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		token := "h." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"1077","email":"a@b.c"}`)) + ".s"
		fmt.Fprintf(w, `{"id_token":%q}`, token)
	})
	mux.HandleFunc("/api/auth/session", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Provider, IDToken string
			Refresh           *bool
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Provider != "google" || !strings.HasPrefix(req.IDToken, "h.") || req.Refresh == nil || *req.Refresh {
			t.Errorf("session request %+v, %v", req, err)
			w.WriteHeader(401)
			return
		}
		fmt.Fprintf(w, `{"token":"pst","expiresAt":%d}`, time.Now().Add(time.Hour).Unix())
	})
	mux.HandleFunc("/api/auth/profile", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer pst" {
			w.WriteHeader(401)
			return
		}
		w.Write([]byte(`{"profile":"automatic_paranoid_axolotl"}`))
	})
	mux.HandleFunc("/api/auth/credentials", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer pst" {
			w.WriteHeader(401)
			return
		}
		w.Write([]byte(`{"identityId":"us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b","token":"tok","tier":"premium","bucket":"bucket"}`))
	})
	mux.HandleFunc("/cognito", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"Credentials":{"AccessKeyId":"AK","SecretKey":"SK","SessionToken":"ST","Expiration":%d}}`, time.Now().Add(time.Hour).Unix())
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	args := []string{"--state-dir", filepath.Join(tmp, "state"), "--s3-endpoint", "http://" + addr}
	if !camera {
		// Two still pictures: no motion between their keyframes.
		args = append(args, "--chunk", "10s", "--motion-min", "0", "--source", "test", "--device", video,
			"--width", "1280", "--height", "720", "--fps", "10", "--bitrate", "1000000")
	}
	o, _ := parse("run", args)
	s, err := state.Load(o.stateDir)
	if err != nil {
		t.Fatal(err)
	}
	s.ProfileID, s.RefreshToken = "automatic_paranoid_axolotl", "rt"
	s.Save()
	api := &presence.API{BaseURL: srv.URL, CognitoURL: srv.URL + "/cognito"}
	sess := &session.Session{Google: &google.Client{ID: "c", Secret: "s", Endpoints: google.Endpoints{Token: srv.URL + "/token"}},
		API: api, RefreshToken: "rt", ProfileID: s.ProfileID, DeviceID: s.DeviceID}
	// Stopped as a signal stops it.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	seconds, err := strconv.Atoi(os.Getenv("PRESENCE_STREAMER_E2E_SECONDS"))
	if err != nil {
		seconds = 45 // more under emulation (PRESENCE_STREAMER_E2E_SECONDS)
	}
	time.AfterFunc(time.Duration(seconds)*time.Second, cancel)
	creds, err := sess.Credentials(ctx)
	if err != nil {
		t.Fatal(err)
	}

	var logs bytes.Buffer
	log.SetOutput(&logs)
	defer log.SetOutput(os.Stderr)
	logf := func(format string, args ...any) {
		t.Logf(format, args...)
		fmt.Fprintf(&logs, format+"\n", args...)
	}
	if code := streamCamera(ctx, o, s, sess, creds, logf); code != 0 {
		t.Fatalf("exit %d\n%s", code, logs.String())
	}

	folder := filepath.Join(root, "bucket", "us-east-1:0f3c1a2b-4d5e-4f60-8a7b-9c0d1e2f3a4b")
	var events, ingest []string
	filepath.Walk(folder, func(path string, info os.FileInfo, err error) error {
		rel, _ := filepath.Rel(folder, path)
		if strings.HasPrefix(rel, "events/") && !info.IsDir() {
			events = append(events, path)
		}
		if strings.HasPrefix(rel, "ingest/") && !info.IsDir() {
			ingest = append(ingest, rel)
		}
		return nil
	})
	if cloud {
		// Every chunk and its job wait in ingest for the cloud detector,
		// and nothing is left here.
		var chunks, jobs int
		for _, key := range ingest {
			switch {
			case strings.HasSuffix(key, ".ingest.json"):
				jobs++
			case strings.HasSuffix(key, ".mp4"):
				chunks++
			}
		}
		// The chunk being uploaded at the stop may wait for its job: the
		// next start uploads it.
		if jobs == 0 || jobs < chunks-1 || jobs > chunks || len(events) != 0 {
			t.Fatalf("%d chunks, %d jobs, %d events\n%s", chunks, jobs, len(events), logs.String())
		}
		left, _ := filepath.Glob(filepath.Join(o.stateDir, "spool", "rec-*.mp4"))
		if len(left) > 1 { // the one being recorded at the stop
			t.Errorf("left in the spool: %v", left)
		}
		return
	}
	if len(events) == 0 {
		t.Fatalf("no event stored\n%s", logs.String())
	}
	if !strings.Contains(logs.String(), "no one there, deleted") {
		t.Errorf("no chunk was deleted as empty")
	}
	key, _ := s.Key()
	for _, path := range events {
		data, _ := os.ReadFile(path)
		var event map[string]any
		json.Unmarshal(data, &event)
		t.Logf("event: %s", data)
		clipID := event["clipId"].(string)
		if !strings.Contains(string(data), `"label":"human"`) || event["deviceId"] != s.DeviceID || event["userId"] != "1077" {
			t.Errorf("event %s", data)
		}
		for _, media := range []string{clipID + ".mp4", clipID + ".jpg"} {
			sealed, err := os.ReadFile(filepath.Join(folder, "media", media))
			if err != nil {
				t.Errorf("no media/%s", media)
				continue
			}
			var plain bytes.Buffer
			if err := seal.Open(&plain, bytes.NewReader(sealed), key); err != nil {
				t.Errorf("media/%s doesn't open: %v", media, err)
			}
		}
	}
	// Only a chunk stopped mid-way may be left in ingest: its progress is
	// in the spool, and the next start finishes it.
	pending := map[string]bool{}
	progress, _ := filepath.Glob(filepath.Join(o.stateDir, "spool", "rec-*.mp4.json"))
	for _, p := range progress {
		data, _ := os.ReadFile(p)
		var chunk struct {
			ClipID string `json:"clipId"`
		}
		json.Unmarshal(data, &chunk)
		pending["ingest/"+s.DeviceID+"/"+chunk.ClipID+".mp4"] = true
	}
	for _, key := range ingest {
		if !pending[key] {
			t.Errorf("left in ingest, not pending in the spool: %s", key)
		}
	}
	settings, err := os.ReadFile(filepath.Join(folder, "devices", s.DeviceID, "settings.json"))
	if err != nil || !strings.Contains(string(settings), `"mediaKey":"`+s.MediaKey+`"`) {
		t.Errorf("settings %s, %v", settings, err)
	}
}
