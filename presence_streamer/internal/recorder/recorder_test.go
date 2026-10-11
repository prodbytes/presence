package recorder

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func config(source, encoder string) Config {
	return Config{Source: source, Encoder: encoder, Width: 1280, Height: 720, FPS: 30, Bitrate: 2500000,
		Chunk: 30 * time.Second, Spool: "/spool", FFmpeg: "ffmpeg", RpicamVid: "rpicam-vid", Device: "/dev/video0"}
}

func joined(t *testing.T, c Config) (string, string) {
	t.Helper()
	camera, ffmpeg, err := c.Commands()
	if err != nil {
		t.Fatal(err)
	}
	return strings.Join(camera, " "), strings.Join(ffmpeg, " ")
}

func TestCommands(t *testing.T) {
	segment := "-f segment -segment_time 30 -segment_format mp4 -segment_format_options movflags=+faststart -reset_timestamps 1 -strftime 1 -segment_list /spool/segments-0.csv -segment_list_type csv /spool/rec-0-%Y%m%dT%H%M%S.mp4"

	camera, ffmpeg := joined(t, config("libcamera", "hw"))
	if camera != "rpicam-vid -n -t 0 --framerate 30 --width 1280 --height 720 --codec h264 --inline --intra 30 --bitrate 2500000 --flush -o -" {
		t.Errorf("libcamera hw camera: %s", camera)
	}
	if ffmpeg != "ffmpeg -hide_banner -loglevel warning -nostdin -f h264 -framerate 30 -i pipe:0 -c:v copy "+segment {
		t.Errorf("libcamera hw ffmpeg: %s", ffmpeg)
	}

	camera, ffmpeg = joined(t, config("libcamera", "sw"))
	if !strings.Contains(camera, "--codec yuv420") || !strings.Contains(ffmpeg, "-f rawvideo -pix_fmt yuv420p -video_size 1280x720") ||
		!strings.Contains(ffmpeg, "-c:v libx264") {
		t.Errorf("libcamera sw: %s | %s", camera, ffmpeg)
	}

	camera, ffmpeg = joined(t, config("v4l2", "hw"))
	if camera != "" || !strings.Contains(ffmpeg, "-f v4l2 -framerate 30 -video_size 1280x720 -i /dev/video0 -c:v h264_v4l2m2m -b:v 2500000 -g 30") {
		t.Errorf("v4l2 hw: %s", ffmpeg)
	}
	if _, ffmpeg = joined(t, config("v4l2", "sw")); !strings.Contains(ffmpeg, "-c:v libx264") || !strings.Contains(ffmpeg, "-g 30 -keyint_min 30") {
		t.Errorf("v4l2 sw: %s", ffmpeg)
	}

	rotated := config("libcamera", "hw")
	rotated.Rotation = 180
	if camera, _ = joined(t, rotated); !strings.Contains(camera, "--rotation 180") {
		t.Errorf("rotation: %s", camera)
	}

	if _, _, err := config("nope", "sw").Commands(); err == nil {
		t.Error("an unknown source has commands")
	}
	none := config("libcamera", "hw")
	none.RpicamVid = ""
	if _, _, err := none.Commands(); err == nil || !strings.Contains(err.Error(), "rpicam-apps") {
		t.Errorf("libcamera without rpicam-vid: %v", err)
	}
}

func TestStartOf(t *testing.T) {
	at, ok := StartOf("/spool/rec-mgk3v1q8h0-20260926T120005.mp4")
	if !ok || !at.Equal(time.Date(2026, 9, 26, 12, 0, 5, 0, time.UTC)) {
		t.Fatalf("%v %v", at, ok)
	}
	if _, ok := StartOf("other.mp4"); ok {
		t.Fatal("a stranger's start")
	}
}

func TestSegments(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, age time.Duration) string {
		path := filepath.Join(dir, name)
		os.WriteFile(path, nil, 0o600)
		at := time.Now().Add(-age)
		os.Chtimes(path, at, at)
		return path
	}
	// Left by an earlier run, named later than this run's (the clock went
	// back since), and older on disk.
	old := write("rec-a-20261011T120000.mp4", time.Hour)
	s := &Segments{Spool: dir}
	list := filepath.Join(dir, "segments-b.csv")
	s.started(list)
	first := write("rec-b-20261011T080000.mp4", 2*time.Minute)
	write("rec-b-20261011T080030.mp4", time.Minute) // being written
	os.WriteFile(list, []byte("rec-b-20261011T080000.mp4,0.000000,30.000000\n"), 0o600)

	got := s.Finished()
	if len(got) != 2 || got[0] != old || got[1] != first {
		t.Fatalf("while recording: %v", got)
	}
	s.stopped()
	if got := s.Finished(); len(got) != 3 {
		t.Fatalf("stopped: %v", got)
	}
	if _, err := os.Stat(list); !os.IsNotExist(err) {
		t.Fatal("the segment list was left behind")
	}
}

// Records the test pattern in 1 s chunks, and stops cleanly.
func TestRecordsChunks(t *testing.T) {
	ffmpeg, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skip("no ffmpeg")
	}
	spool := t.TempDir()
	c := Config{Source: "test", Width: 320, Height: 240, FPS: 10, Bitrate: 300000, Chunk: time.Second,
		Spool: spool, FFmpeg: ffmpeg, Log: os.Stderr}
	ctx, cancel := context.WithTimeout(context.Background(), 3500*time.Millisecond)
	defer cancel()
	segments := &Segments{Spool: spool}
	// Mid-way, the finished chunks are ffmpeg's listed ones, never the one
	// it's writing.
	var during []string
	var all int
	time.AfterFunc(2500*time.Millisecond, func() {
		during = segments.Finished()
		all = len(chunks(spool))
	})
	if err := Run(ctx, c, segments, t.Logf); err != nil {
		t.Fatal(err)
	}
	if len(during) == 0 || len(during) != all-1 {
		t.Fatalf("mid-way: %d finished of %d", len(during), all)
	}
	chunks := segments.Finished()
	if len(chunks) < 3 {
		t.Fatalf("chunks %v", chunks)
	}
	at, ok := StartOf(chunks[0])
	if !ok || time.Since(at) > time.Minute || time.Since(at) < 0 {
		t.Fatalf("first chunk %s starts at %v", chunks[0], at)
	}
	ffprobe, _ := exec.LookPath("ffprobe")
	for _, chunk := range chunks {
		if out, err := exec.Command(ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", chunk).Output(); err != nil {
			t.Errorf("%s isn't a playable MP4 (%v): %s", chunk, err, out)
		}
	}
}
