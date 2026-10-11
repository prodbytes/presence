// Package detect searches chunks for people and animals: ffmpeg decodes a
// chunk's keyframes (one a second, as the recorder makes them) to JPEGs,
// and the detector (detector/presence-detect.py, kept running) looks at
// them.
package detect

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Object is a label's best score in a chunk, and when.
type Object struct {
	Label string  `json:"label"`
	Ms    int64   `json:"ms"`
	Score float64 `json:"score"`
}

// Result is what was found in a chunk.
type Result struct {
	Objects []Object `json:"objects"`
	// Subject is the best person or animal, nil when there's none; its
	// frame is the thumbnail.
	Subject *Object `json:"subject"`
	Error   string  `json:"error"`
}

// Frame is a frame to search, and its time in the chunk.
type Frame struct {
	Path string `json:"path"`
	Ms   int64  `json:"ms"`
}

// ErrBroken is a chunk ffprobe or ffmpeg ran on and couldn't read (cut
// off by a power cut, say): nothing in it to keep.
var ErrBroken = errors.New("the chunk is broken")

// ErrUnavailable is a detector that doesn't start (OpenCV or the models
// missing): no chunk's fault.
var ErrUnavailable = errors.New("the detector isn't available")

// Detector is the detector process, started on first use and again
// after it dies.
type Detector struct {
	// Command runs the detector (python3 presence-detect.py --cfg …).
	Command []string
	// Log gets its stderr.
	Log io.Writer

	mu  sync.Mutex
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
	// proc is the running process, for Close to kill without waiting for
	// a search.
	proc atomic.Pointer[os.Process]
}

func (d *Detector) start() error {
	cmd := exec.Command(d.Command[0], d.Command[1:]...)
	cmd.Stderr = d.Log
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	d.cmd, d.in, d.out = cmd, in, bufio.NewReaderSize(out, 64*1024)
	d.proc.Store(cmd.Process)
	line, err := d.out.ReadBytes('\n')
	var ready struct {
		Ready bool `json:"ready"`
	}
	if err != nil || json.Unmarshal(line, &ready) != nil || !ready.Ready {
		d.stop()
		return fmt.Errorf("%w: it didn't start (%v): see its log", ErrUnavailable, err)
	}
	return nil
}

func (d *Detector) stop() {
	if d.cmd == nil {
		return
	}
	d.in.Close()
	_ = d.cmd.Process.Kill()
	_ = d.cmd.Wait()
	d.cmd = nil
	d.proc.Store(nil)
}

// Close stops the detector, at once: a search under way fails.
func (d *Detector) Close() {
	if p := d.proc.Load(); p != nil {
		_ = p.Kill()
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.stop()
}

// Search searches frames, writing the subject's frame to thumbnail.
func (d *Detector) Search(frames []Frame, thumbnail string) (Result, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.cmd == nil {
		if err := d.start(); err != nil {
			return Result{}, err
		}
	}
	req, _ := json.Marshal(map[string]any{"frames": frames, "thumbnail": thumbnail})
	if _, err := d.in.Write(append(req, '\n')); err != nil {
		d.stop()
		return Result{}, fmt.Errorf("the detector stopped: %w", err)
	}
	line, err := d.out.ReadBytes('\n')
	if err != nil {
		d.stop()
		return Result{}, fmt.Errorf("the detector stopped: %w", err)
	}
	var r Result
	if err := json.Unmarshal(line, &r); err != nil {
		return r, fmt.Errorf("the detector answered %q", strings.TrimSpace(string(line)))
	}
	if r.Error != "" {
		return r, errors.New("the detector failed: " + r.Error)
	}
	return r, nil
}

// Duration is how long a chunk is, from ffprobe; an error means it's
// broken (cut off by a power cut, say).
func Duration(ctx context.Context, ffprobe, chunk string) (time.Duration, error) {
	out, err := exec.CommandContext(ctx, ffprobe, "-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", chunk).Output()
	if err != nil {
		return 0, ranAndFailed(ctx, fmt.Sprintf("ffprobe %s", filepath.Base(chunk)), err)
	}
	seconds, err := strconv.ParseFloat(strings.TrimSpace(string(out)), 64)
	if err != nil || seconds <= 0 {
		return 0, fmt.Errorf("%w: ffprobe %s: no duration (%q)", ErrBroken, filepath.Base(chunk), strings.TrimSpace(string(out)))
	}
	return time.Duration(seconds * float64(time.Second)), nil
}

// Keyframes decodes chunk's keyframes into dir (at most 1280 px wide) and
// lists them with their times: the recorder makes one every second, so
// the n-th is at about n-1 s. Only keyframes are decoded, which is cheap.
func Keyframes(ctx context.Context, ffmpeg, chunk, dir string, every time.Duration) ([]Frame, error) {
	cmd := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
		"-skip_frame", "nokey", "-i", chunk,
		"-vf", "scale='min(1280,iw)':-2", "-fps_mode", "passthrough", "-q:v", "3",
		filepath.Join(dir, "f%04d.jpg"))
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, ranAndFailed(ctx, fmt.Sprintf("ffmpeg keyframes of %s: %s", filepath.Base(chunk), strings.TrimSpace(string(out))), err)
	}
	names, err := filepath.Glob(filepath.Join(dir, "f*.jpg"))
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	frames := make([]Frame, len(names))
	for i, name := range names {
		frames[i] = Frame{Path: name, Ms: int64(i) * every.Milliseconds()}
	}
	return frames, nil
}

// ranAndFailed is err from a tool: ErrBroken when it ran and failed on the
// chunk, else (not started, cancelled, killed) as it is.
func ranAndFailed(ctx context.Context, what string, err error) error {
	var exit *exec.ExitError
	if ctx.Err() == nil && errors.As(err, &exit) && exit.Exited() {
		return fmt.Errorf("%w: %s: %v", ErrBroken, what, err)
	}
	return fmt.Errorf("%s: %w", what, err)
}

// Clean removes dir's frames.
func Clean(dir string) {
	names, _ := filepath.Glob(filepath.Join(dir, "f*.jpg"))
	for _, n := range names {
		os.Remove(n)
	}
}
