package detect

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func frame(fill func(i int) byte) []byte {
	f := make([]byte, motionWidth*motionHeight)
	for i := range f {
		f[i] = fill(i)
	}
	return f
}

func TestMotionScore(t *testing.T) {
	gray := frame(func(int) byte { return 100 })
	if s := MotionScore(gray, gray); s != 0 {
		t.Errorf("no change: %v", s)
	}
	// The whole picture brighter (exposure, a light): no motion.
	if s := MotionScore(gray, frame(func(int) byte { return 160 })); s != 0 {
		t.Errorf("a brightness shift: %v", s)
	}
	// Something covering a tenth of the picture, with the rest brighter too.
	tenth := len(gray) / 10
	moved := frame(func(i int) byte {
		if i < tenth {
			return 250
		}
		return 120
	})
	if s := MotionScore(gray, moved); s < 9.9 || s > 10.1 {
		t.Errorf("a tenth moved: %v", s)
	}
	// Small changes (noise) don't count.
	if s := MotionScore(gray, frame(func(i int) byte { return byte(100 + i%20) })); s != 0 {
		t.Errorf("noise: %v", s)
	}
	if MotionScore(nil, nil) != 0 || MotionScore(gray, gray[:10]) != 0 {
		t.Error("frames that don't match")
	}
}

func TestMotion(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	dir := t.TempDir()
	make := func(name, source string) string {
		path := filepath.Join(dir, name)
		if out, err := exec.Command(ffmpeg, "-loglevel", "error", "-f", "lavfi", "-i", source, "-t", "4",
			"-c:v", "libx264", "-g", "10", "-keyint_min", "10", "-sc_threshold", "0", "-pix_fmt", "yuv420p", path).CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
		return path
	}
	ctx := context.Background()
	still, frames, err := Motion(ctx, ffmpeg, make("still.mp4", "color=gray:s=640x360:r=10"))
	if err != nil || still > 1 || frames != 4 {
		t.Errorf("a still picture: %v%% over %d keyframes, %v", still, frames, err)
	}
	// ffmpeg's moving test pattern.
	moving, _, err := Motion(ctx, ffmpeg, make("moving.mp4", "testsrc2=s=640x360:r=10"))
	if err != nil || moving < 5 {
		t.Errorf("a moving box: %v%%, %v", moving, err)
	}
	broken := filepath.Join(dir, "broken.mp4")
	os.WriteFile(broken, []byte("not a video"), 0o600)
	if _, _, err := Motion(ctx, ffmpeg, broken); !errors.Is(err, ErrBroken) {
		t.Errorf("a broken chunk: %v", err)
	}
}
