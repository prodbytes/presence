package rclone

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/presence"
)

func creds(context.Context) (presence.AWS, error) {
	return presence.AWS{AccessKeyID: "AK", SecretKey: "SECRETKEY", SessionToken: "ST"}, nil
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
	data, _ := os.ReadFile(log)
	out := string(data)
	for _, want := range []string{
		"ARGS copyto /spool/x.sealed :s3:b/us-east-1:abc/ingest/d/x.mp4 --header-upload Content-Type: application/octet-stream --config /dev/null --s3-no-check-bucket",
		"ARGS moveto :s3:b/us-east-1:abc/ingest/d/x.mp4 :s3:b/us-east-1:abc/media/x.mp4",
		"ARGS deletefile :s3:b/us-east-1:abc/ingest/d/y.mp4",
		"RCLONE_S3_SECRET_ACCESS_KEY=SECRETKEY",
		"RCLONE_S3_SESSION_TOKEN=ST",
		"RCLONE_S3_STORAGE_CLASS=INTELLIGENT_TIERING",
		"RCLONE_S3_PROVIDER=AWS",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "ARGS") && (strings.Contains(line, "SECRETKEY") || strings.Contains(line, "ST ")) {
			t.Errorf("a secret on the command line: %s", line)
		}
	}
}

// Against rclone's own S3 server, when rclone is installed (RCLONE names
// another binary).
func TestAgainstS3(t *testing.T) {
	bin := os.Getenv("RCLONE")
	if bin == "" {
		var err error
		if bin, err = exec.LookPath("rclone"); err != nil {
			t.Skip("no rclone")
		}
	}
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
