package detect

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A detector that answers a subject for requests naming "person", and
// dies on "die".
const fake = `echo '{"ready":true}'
while read -r line; do
  case "$line" in
    *die*) exit 1 ;;
    *person*) echo '{"objects":[{"label":"human","ms":1000,"score":0.9}],"subject":{"label":"human","ms":1000,"score":0.9}}' ;;
    *) echo '{"objects":[],"subject":null}' ;;
  esac
done`

func TestDetector(t *testing.T) {
	d := &Detector{Command: []string{"sh", "-c", fake}, Log: os.Stderr}
	defer d.Close()
	r, err := d.Search([]Frame{{Path: "/x/person.jpg"}}, "/x/t.jpg")
	if err != nil || r.Subject == nil || r.Subject.Label != "human" || len(r.Objects) != 1 {
		t.Fatalf("person: %+v, %v", r, err)
	}
	r, err = d.Search([]Frame{{Path: "/x/empty.jpg"}}, "")
	if err != nil || r.Subject != nil {
		t.Fatalf("empty: %+v, %v", r, err)
	}
	if _, err := d.Search([]Frame{{Path: "/x/die.jpg"}}, ""); err == nil {
		t.Fatal("a dead detector answered")
	}
	// Started again after it died.
	if r, err := d.Search([]Frame{{Path: "/x/person.jpg"}}, ""); err != nil || r.Subject == nil {
		t.Fatalf("after a restart: %+v, %v", r, err)
	}
}

func TestDetectorThatDoesNotStart(t *testing.T) {
	d := &Detector{Command: []string{"sh", "-c", "echo oops; exit 1"}}
	if _, err := d.Search(nil, ""); err == nil || !strings.Contains(err.Error(), "didn't start") {
		t.Fatalf("got %v", err)
	}
}

func TestKeyframesAndDuration(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	ffprobe, _ := exec.LookPath("ffprobe")
	dir := t.TempDir()
	chunk := filepath.Join(dir, "chunk.mp4")
	// 5 s at 10 fps, a keyframe a second, as the recorder makes them.
	if out, err := exec.Command(ffmpeg, "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10",
		"-t", "5", "-c:v", "libx264", "-g", "10", "-keyint_min", "10", "-sc_threshold", "0", chunk).CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	ctx := context.Background()
	d, err := Duration(ctx, ffprobe, chunk)
	if err != nil || d < 4900*time.Millisecond || d > 5100*time.Millisecond {
		t.Fatalf("duration %v, %v", d, err)
	}
	frames, err := Keyframes(ctx, ffmpeg, chunk, dir, time.Second)
	if err != nil || len(frames) != 5 || frames[4].Ms != 4000 {
		t.Fatalf("frames %+v, %v", frames, err)
	}
	Clean(dir)
	if left, _ := filepath.Glob(filepath.Join(dir, "f*.jpg")); len(left) != 0 {
		t.Fatal("frames left behind")
	}
	broken := filepath.Join(dir, "broken.mp4")
	os.WriteFile(broken, []byte("not a video"), 0o600)
	if _, err := Duration(ctx, ffprobe, broken); err == nil {
		t.Fatal("a broken chunk has a duration")
	}
}
