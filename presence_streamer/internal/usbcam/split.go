package usbcam

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// SplitVideo cuts video into chunks of about every, as the Pi's recorder
// does (ffmpeg's segment muxer), copied, not encoded again: each starts at
// a keyframe. They're made in dir, named by their UTC start
// (ChunkName: the video's start plus the chunk's, from ffmpeg's segment
// list). Only the video's first video and audio streams go in them, and
// no timecode track (a GoPro's timecode and telemetry streams don't fit an
// MP4 chunk).
func SplitVideo(ctx context.Context, ffmpeg, video, dir string, start time.Time, every time.Duration) error {
	list := filepath.Join(dir, "segments.csv")
	defer os.Remove(list)
	cmd := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
		"-i", video, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
		"-f", "segment",
		"-segment_time", strconv.FormatFloat(every.Seconds(), 'f', -1, 64),
		"-segment_format", "mp4",
		"-segment_format_options", "movflags=+faststart:write_tmcd=0",
		"-reset_timestamps", "1",
		"-segment_list", list, "-segment_list_type", "csv",
		filepath.Join(dir, "part-%05d.mp4"))
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ffmpeg: %v: %s", err, lastLines(stderr.String(), 2))
	}
	data, err := os.ReadFile(list)
	if err != nil {
		return err
	}
	n := 0
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		// part-00000.mp4,0.000000,30.030000
		fields := strings.Split(strings.TrimSpace(sc.Text()), ",")
		if len(fields) < 2 {
			continue
		}
		offset, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			continue
		}
		at := start.Add(time.Duration(offset * float64(time.Second))).Truncate(time.Second)
		// A name of its own (two chunks within a second: the next second).
		for {
			if _, err := os.Stat(filepath.Join(dir, ChunkName(at))); os.IsNotExist(err) {
				break
			}
			at = at.Add(time.Second)
		}
		if err := os.Rename(filepath.Join(dir, filepath.Base(fields[0])), filepath.Join(dir, ChunkName(at))); err != nil {
			return err
		}
		n++
	}
	if n == 0 {
		return fmt.Errorf("ffmpeg made no chunks of %s", filepath.Base(video))
	}
	// Anything ffmpeg made and didn't list isn't whole.
	parts, _ := filepath.Glob(filepath.Join(dir, "part-*.mp4"))
	for _, p := range parts {
		os.Remove(p)
	}
	return nil
}
