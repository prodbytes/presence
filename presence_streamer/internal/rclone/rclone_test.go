package rclone

import (
	"context"
	"crypto/md5"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/presence"
)

func creds(context.Context) (presence.AWS, error) {
	return presence.AWS{AccessKeyID: "AK", SecretKey: "SECRETKEY", SessionToken: "ST"}, nil
}

// A missing object is os.ErrNotExist.
func TestGetOfAMissingObjectIsNotExist(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "rclone")
	os.WriteFile(fake, []byte("#!/bin/sh\necho 'ERROR : blink.json: object not found' >&2\nexit 3\n"), 0o755)
	f := &Folder{Rclone: fake, Config: "/dev/null", Bucket: "b", Identity: "us-east-1:abc", Region: "us-east-1", Credentials: creds}
	err := f.Get(context.Background(), "devices/d/blink.json", filepath.Join(dir, "x"))
	if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("got %v, want os.ErrNotExist", err)
	}
}

// A fake rclone that writes its arguments and S3 environment to a file.
func TestCommandsKeepSecretsOffTheCommandLine(t *testing.T) {
	dir := t.TempDir()
	log := filepath.Join(dir, "log")
	fake := filepath.Join(dir, "rclone")
	os.WriteFile(fake, []byte("#!/bin/sh\necho \"ARGS $*\" >> "+log+"\nenv | grep '^RCLONE_S3_' | sort >> "+log+"\n"), 0o755)
	f := &Folder{Rclone: fake, Config: "/dev/null", Bucket: "b", Identity: "us-east-1:abc", Region: "us-east-1", Credentials: creds}
	ctx := context.Background()
	if err := f.Put(ctx, "/spool/x.sealed", "ingest/d/x.mp4", "application/octet-stream"); err != nil {
		t.Fatal(err)
	}
	f.Move(ctx, "ingest/d/x.mp4", "media/x.mp4")
	f.Delete(ctx, "ingest/d/y.mp4")
	f.Get(ctx, "devices/d/blink.json", "/spool/blink.json")
	data, _ := os.ReadFile(log)
	out := string(data)
	for _, want := range []string{
		"ARGS copyto /spool/x.sealed :s3:b/us-east-1:abc/ingest/d/x.mp4 --header-upload Content-Type: application/octet-stream --config /dev/null --s3-no-check-bucket",
		"ARGS moveto :s3:b/us-east-1:abc/ingest/d/x.mp4 :s3:b/us-east-1:abc/media/x.mp4",
		"ARGS deletefile :s3:b/us-east-1:abc/ingest/d/y.mp4",
		"ARGS copyto :s3:b/us-east-1:abc/devices/d/blink.json /spool/blink.json",
		"RCLONE_S3_SECRET_ACCESS_KEY=SECRETKEY",
		"RCLONE_S3_SESSION_TOKEN=ST",
		"RCLONE_S3_STORAGE_CLASS=INTELLIGENT_TIERING",
		"RCLONE_S3_PROVIDER=AWS",
		// What's there already counts by size and MD5.
		"--checksum",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	// Nothing turns rclone's verification off.
	for _, never := range []string{"--ignore-checksum", "--ignore-size", "--s3-disable-checksum", "--size-only"} {
		if strings.Contains(out, never) {
			t.Errorf("%s in:\n%s", never, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "ARGS") && (strings.Contains(line, "SECRETKEY") || strings.Contains(line, "ST ")) {
			t.Errorf("a secret on the command line: %s", line)
		}
	}
}

// rcloneBin is the rclone the tests run (RCLONE, else the one on PATH); the
// test is skipped without one.
func rcloneBin(t *testing.T) string {
	t.Helper()
	if bin := os.Getenv("RCLONE"); bin != "" {
		return bin
	}
	bin, err := exec.LookPath("rclone")
	if err != nil {
		t.Skip("no rclone")
	}
	return bin
}

// s3 is a fake S3 for one key at a time: it keeps the objects PUT (and
// checks their Content-MD5, as S3 does), answers a server-side copy, and
// can answer a wrong ETag (a copy that doesn't match).
type s3 struct {
	mu      sync.Mutex
	objects map[string][]byte
	ops     []string
	// wrongPut: the ETag a PUT answers isn't the object's MD5; wrongHead:
	// nor the one a HEAD of that key answers.
	wrongPut  bool
	wrongHead string
}

func etag(data []byte, wrong bool) string {
	if wrong {
		data = append([]byte("not "), data...)
	}
	return fmt.Sprintf(`"%x"`, md5.Sum(data))
}

func (s *s3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := r.URL.Path
	s.ops = append(s.ops, r.Method+" "+key)
	data, ok := s.objects[key]
	switch r.Method {
	case http.MethodHead, http.MethodGet:
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(data)))
		w.Header().Set("ETag", etag(data, key == s.wrongHead))
		w.Header().Set("Last-Modified", time.Now().UTC().Format(http.TimeFormat))
		if r.Method == http.MethodGet {
			w.Write(data)
		}
	case http.MethodPut:
		if from := r.Header.Get("X-Amz-Copy-Source"); from != "" {
			from, _ = url.PathUnescape(from)
			src, ok := s.objects["/"+strings.TrimPrefix(from, "/")]
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			s.objects[key] = src
			fmt.Fprintf(w, `<CopyObjectResult><ETag>%s</ETag><LastModified>%s</LastModified></CopyObjectResult>`,
				etag(src, false), time.Now().UTC().Format(time.RFC3339))
			return
		}
		body, _ := io.ReadAll(r.Body)
		sum := md5.Sum(body)
		if r.Header.Get("Content-MD5") != base64.StdEncoding.EncodeToString(sum[:]) {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, `<Error><Code>BadDigest</Code></Error>`)
			return
		}
		s.objects[key] = body
		w.Header().Set("ETag", etag(body, s.wrongPut))
	case http.MethodDelete:
		delete(s.objects, key)
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusNotImplemented)
	}
}

func (s *s3) count(op string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, o := range s.ops {
		if strings.HasPrefix(o, op) {
			n++
		}
	}
	return n
}

// Uploads and moves are verified by size and MD5 (the PUT's ETag, the
// copy's HEAD): one that doesn't match fails, ErrNotVerified, and leaves no
// copy; a PUT isn't followed by a HEAD; an object already there whole isn't
// uploaded again.
func TestUploadsAndMovesAreVerified(t *testing.T) {
	bin := rcloneBin(t)
	fake := &s3{objects: map[string][]byte{}}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	f := &Folder{Rclone: bin, Config: filepath.Join(t.TempDir(), "rclone.conf"), Bucket: "bucket",
		Identity: "us-east-1:abc", Region: "us-east-1", Endpoint: srv.URL, Credentials: creds}
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "chunk.sealed")
	os.WriteFile(src, []byte("sealed bytes"), 0o600)
	obj := func(key string) ([]byte, bool) {
		fake.mu.Lock()
		defer fake.mu.Unlock()
		data, ok := fake.objects["/bucket/us-east-1:abc/"+key]
		return data, ok
	}

	fake.wrongPut = true
	err := f.Put(ctx, src, "ingest/d/c.mp4", "application/octet-stream")
	if !errors.Is(err, ErrNotVerified) {
		t.Fatalf("a PUT answering another MD5: %v", err)
	}
	if _, ok := obj("ingest/d/c.mp4"); ok {
		t.Fatal("the copy that doesn't match is still there")
	}

	fake.wrongPut = false
	heads := fake.count("HEAD")
	if err := f.Put(ctx, src, "ingest/d/c.mp4", "application/octet-stream"); err != nil {
		t.Fatal(err)
	}
	if data, _ := obj("ingest/d/c.mp4"); string(data) != "sealed bytes" {
		t.Fatalf("uploaded %q", data)
	}
	// One HEAD (is it there?) before the PUT, none after.
	if n := fake.count("HEAD") - heads; n != 1 {
		t.Fatalf("%d HEADs for one upload", n)
	}
	puts := fake.count("PUT")
	if err := f.Put(ctx, src, "ingest/d/c.mp4", "application/octet-stream"); err != nil || fake.count("PUT") != puts {
		t.Fatalf("uploaded again: %v", err)
	}

	fake.wrongHead = "/bucket/us-east-1:abc/media/c.mp4"
	if err := f.Move(ctx, "ingest/d/c.mp4", "media/c.mp4"); !errors.Is(err, ErrNotVerified) {
		t.Fatalf("a move whose copy doesn't match: %v", err)
	}
	if _, ok := obj("ingest/d/c.mp4"); !ok {
		t.Fatal("the source was deleted")
	}
	fake.wrongHead = ""
	if err := f.Move(ctx, "ingest/d/c.mp4", "media/c.mp4"); err != nil {
		t.Fatal(err)
	}
	if _, ok := obj("ingest/d/c.mp4"); ok {
		t.Fatal("the source is still there")
	}
	if data, _ := obj("media/c.mp4"); string(data) != "sealed bytes" {
		t.Fatalf("moved %q", data)
	}
}

// Against rclone's own S3 server, when rclone is installed (RCLONE names
// another binary).
func TestAgainstS3(t *testing.T) {
	bin := rcloneBin(t)
	root := t.TempDir()
	os.MkdirAll(filepath.Join(root, "bucket"), 0o755)
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := l.Addr().String()
	l.Close()
	server := exec.Command(bin, "serve", "s3", root, "--addr", addr, "--config", "/dev/null", "-q")
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	defer server.Process.Kill()
	for i := 0; i < 50; i++ {
		if c, err := net.Dial("tcp", addr); err == nil {
			c.Close()
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	f := &Folder{Rclone: bin, Config: filepath.Join(t.TempDir(), "rclone.conf"), Bucket: "bucket",
		Identity: "us-east-1:abc", Region: "us-east-1", Endpoint: "http://" + addr, Credentials: func(context.Context) (presence.AWS, error) {
			// serve s3 runs without auth here: it knows no session tokens.
			return presence.AWS{AccessKeyID: "AK", SecretKey: "SECRETKEY"}, nil
		}}
	ctx := context.Background()
	src := filepath.Join(t.TempDir(), "chunk.sealed")
	os.WriteFile(src, []byte("sealed bytes"), 0o600)
	folder := filepath.Join(root, "bucket", "us-east-1:abc")

	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(f.Put(ctx, src, "ingest/d/c1.mp4", "application/octet-stream"))
	must(f.Put(ctx, src, "ingest/d/c2.mp4", "application/octet-stream"))
	must(f.Move(ctx, "ingest/d/c1.mp4", "media/c1.mp4"))
	must(f.Delete(ctx, "ingest/d/c2.mp4"))

	if data, err := os.ReadFile(filepath.Join(folder, "media", "c1.mp4")); err != nil || string(data) != "sealed bytes" {
		t.Fatalf("media/c1.mp4: %q, %v", data, err)
	}
	for _, gone := range []string{"ingest/d/c1.mp4", "ingest/d/c2.mp4"} {
		if _, err := os.Stat(filepath.Join(folder, gone)); !os.IsNotExist(err) {
			t.Errorf("%s is still there", gone)
		}
	}
	if err := f.Delete(ctx, "ingest/d/missing.mp4"); err == nil {
		fmt.Println("deleting a missing object succeeds") // S3 does that; rclone may not
	}
}
