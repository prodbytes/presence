// Package recorder records the camera continuously into chunks: H.264,
// hardware-encoded where the Pi has an encoder, cut by ffmpeg into MP4
// files of a fixed length (at keyframes, one a second) in the spool.
//
//   - Camera module (libcamera): rpicam-vid (libcamera-vid on older
//     systems) encodes with the Pi's H.264 encoder (Pi 4 and earlier; a
//     Pi 5, which has none, with libx264) into MPEG-TS, and ffmpeg only
//     cuts the stream (-c copy).
//   - USB camera (v4l2): ffmpeg reads it and encodes with h264_v4l2m2m (the
//     Pi's encoder) or libx264.
//   - test: ffmpeg's test pattern, or a video file played in a loop, for
//     development without a camera.
package recorder

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Config says what to record and how.
type Config struct {
	// Source is auto, libcamera, v4l2 or test.
	Source string
	// Device is the v4l2 device (/dev/video0), or test's video file
	// (empty: the test pattern).
	Device string
	// Encoder is auto, hw (the Pi's H.264 encoder) or sw (libx264).
	Encoder            string
	Width, Height, FPS int
	Bitrate            int // bits/s
	Chunk              time.Duration
	Spool              string
	FFmpeg, RpicamVid  string
	// Rotation is 0 or 180 (camera module only: --rotation).
	Rotation int
	// Log gets the recorder's stderr.
	Log io.Writer
	// Run names this run's chunks and segment list (Run sets it).
	Run string
}

// pattern names a run's chunks: rec-<run>-<UTC start>.mp4. The run (a new
// one each time ffmpeg starts) keeps names unique when the clock goes back
// (a Pi's fake-hwclock at boot, until the network sets it).
func pattern(run string) string { return "rec-" + run + "-%Y%m%dT%H%M%S.mp4" }

// timeLayout is a chunk name's time (in the layout, ".mp4" would be read as
// part of the time, so it's cut off first).
const timeLayout = "20060102T150405"

// StartOf is when the chunk named name started (from its name).
func StartOf(name string) (time.Time, bool) {
	base := filepath.Base(name)
	if !strings.HasPrefix(base, "rec-") || !strings.HasSuffix(base, ".mp4") {
		return time.Time{}, false
	}
	stamp := strings.TrimSuffix(base, ".mp4")
	stamp = stamp[strings.LastIndex(stamp, "-")+1:]
	t, err := time.Parse(timeLayout, stamp)
	return t, err == nil
}

// HasHardwareEncoder says whether the Pi has its H.264 encoder (the
// bcm2835 codec's encode device, on a Pi 4 and earlier; a Pi 5 has none).
func HasHardwareEncoder() bool {
	names, _ := filepath.Glob("/sys/class/video4linux/video*/name")
	for _, n := range names {
		if data, err := os.ReadFile(n); err == nil && strings.Contains(string(data), "codec-encode") {
			return true
		}
	}
	return false
}

// FindRpicamVid is rpicam-vid, or libcamera-vid on older systems; empty
// when neither is installed.
func FindRpicamVid() string {
	for _, name := range []string{"rpicam-vid", "libcamera-vid"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
}

// HasCameraModule says whether libcamera sees a camera.
func HasCameraModule(rpicamVid string) bool {
	if rpicamVid == "" {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, rpicamVid, "--list-cameras").CombinedOutput()
	return err == nil && strings.Contains(string(out), "Available cameras") &&
		!strings.Contains(string(out), "No cameras available")
}

// Resolve settles auto: the camera module if libcamera sees one, else a
// USB camera; the hardware encoder if the Pi has one.
func (c Config) Resolve() Config {
	if c.Source == "auto" || c.Source == "" {
		if HasCameraModule(c.RpicamVid) {
			c.Source = "libcamera"
		} else {
			c.Source = "v4l2"
		}
	}
	if c.Encoder == "auto" || c.Encoder == "" {
		if c.Source != "test" && HasHardwareEncoder() {
			c.Encoder = "hw"
		} else {
			c.Encoder = "sw"
		}
	}
	if c.Device == "" && c.Source == "v4l2" {
		c.Device = "/dev/video0"
	}
	return c
}

func (c Config) segment() []string {
	return []string{
		"-f", "segment",
		"-segment_time", strconv.FormatFloat(c.Chunk.Seconds(), 'f', -1, 64),
		"-segment_format", "mp4",
		"-segment_format_options", "movflags=+faststart",
		"-reset_timestamps", "1",
		"-strftime", "1",
		// ffmpeg adds each chunk here once it has finished it.
		"-segment_list", c.list(), "-segment_list_type", "csv",
		filepath.Join(c.Spool, pattern(c.run())),
	}
}

func (c Config) run() string {
	if c.Run == "" {
		return "0"
	}
	return c.Run
}

// list is the run's segment list: the chunks ffmpeg has finished.
func (c Config) list() string { return filepath.Join(c.Spool, "segments-"+c.run()+".csv") }

func (c Config) size() string { return fmt.Sprintf("%dx%d", c.Width, c.Height) }

func (c Config) x264() []string {
	fps := strconv.Itoa(c.FPS)
	return []string{"-c:v", "libx264", "-preset", "veryfast", "-tune", "zerolatency",
		"-b:v", strconv.Itoa(c.Bitrate), "-maxrate", strconv.Itoa(c.Bitrate), "-bufsize", strconv.Itoa(2 * c.Bitrate),
		"-g", fps, "-keyint_min", fps, "-sc_threshold", "0", "-pix_fmt", "yuv420p"}
}

func (c Config) v4l2m2m() []string {
	fps := strconv.Itoa(c.FPS)
	return []string{"-c:v", "h264_v4l2m2m", "-b:v", strconv.Itoa(c.Bitrate), "-g", fps, "-pix_fmt", "yuv420p"}
}

var ffmpegStart = []string{"-hide_banner", "-loglevel", "warning", "-nostdin"}

// Commands are the recorder's commands: the camera's, piped into
// ffmpeg's, or ffmpeg's alone (camera nil).
func (c Config) Commands() (camera, ffmpeg []string, err error) {
	fps := strconv.Itoa(c.FPS)
	switch c.Source {
	case "libcamera":
		if c.RpicamVid == "" {
			return nil, nil, fmt.Errorf("the camera module needs rpicam-vid (sudo apt install rpicam-apps)")
		}
		camera = []string{c.RpicamVid, "-n", "-t", "0", "--framerate", fps,
			"--width", strconv.Itoa(c.Width), "--height", strconv.Itoa(c.Height)}
		if c.Rotation == 180 {
			camera = append(camera, "--rotation", "180")
		}
		// rpicam-vid encodes (the Pi's encoder, or libx264 on a Pi 5) and
		// sends MPEG-TS, which carries each frame's real time: a Pi that
		// can't keep up the frame rate (a Zero at 720p makes about 23 fps)
		// still makes chunks as long as the time they cover. Raw H.264 has
		// no times, and ffmpeg would assume the asked-for rate.
		codec := "h264_v4l2m2m"
		if c.Encoder != "hw" {
			codec = "libx264"
		}
		camera = append(camera, "--codec", "libav", "--libav-format", "mpegts", "--libav-video-codec", codec,
			"--intra", fps, "--bitrate", strconv.Itoa(c.Bitrate), "-o", "-")
		ffmpeg = append([]string{c.FFmpeg}, ffmpegStart...)
		ffmpeg = append(ffmpeg, "-f", "mpegts", "-i", "pipe:0", "-c:v", "copy")
	case "v4l2":
		ffmpeg = append([]string{c.FFmpeg}, ffmpegStart...)
		ffmpeg = append(ffmpeg, "-f", "v4l2", "-framerate", fps, "-video_size", c.size(), "-i", c.Device)
		if c.Encoder == "hw" {
			ffmpeg = append(ffmpeg, c.v4l2m2m()...)
		} else {
			ffmpeg = append(ffmpeg, c.x264()...)
		}
	case "test":
		ffmpeg = append([]string{c.FFmpeg}, ffmpegStart...)
		if c.Device == "" {
			ffmpeg = append(ffmpeg, "-re", "-f", "lavfi", "-i", "testsrc2=size="+c.size()+":rate="+fps)
		} else {
			ffmpeg = append(ffmpeg, "-re", "-stream_loop", "-1", "-i", c.Device, "-an",
				"-vf", "scale="+strconv.Itoa(c.Width)+":-2,fps="+fps)
		}
		ffmpeg = append(ffmpeg, c.x264()...)
	default:
		return nil, nil, fmt.Errorf("unknown source %q: use auto, libcamera, v4l2 or test", c.Source)
	}
	return camera, append(ffmpeg, c.segment()...), nil
}

// Segments says which of the spool's chunks are finished: those there
// before the running ffmpeg started, and those it lists as done; every one
// while none runs. Not "all but the newest name", which a clock gone back
// would make wrong.
type Segments struct {
	Spool string

	mu     sync.Mutex
	list   string          // the running ffmpeg's segment list; "" when none runs
	before map[string]bool // the chunks there before it started
	// done are the chunks the list says are finished, read from it a line
	// at a time (read is how far): the list keeps growing while ffmpeg runs.
	done map[string]bool
	read int64
	// lengths are the chunks' lengths, from the segment lists' start and
	// end times (ffmpeg's, so no ffprobe is needed: on a Pi Zero that's
	// seconds a chunk).
	lengths map[string]time.Duration
}

// Length is a finished chunk's length, as ffmpeg listed it; false when it
// didn't (a chunk from an earlier run).
func (s *Segments) Length(chunk string) (time.Duration, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.lengths[filepath.Base(chunk)]
	return d, ok && d > 0
}

func chunks(spool string) []string {
	names, _ := filepath.Glob(filepath.Join(spool, "rec-*.mp4"))
	return names
}

func (s *Segments) started(list string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.before = map[string]bool{}
	for _, n := range chunks(s.Spool) {
		s.before[n] = true
	}
	s.list, s.done, s.read = list, map[string]bool{}, 0
}

func (s *Segments) stopped() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.list != "" {
		os.Remove(s.list)
	}
	s.list = ""
}

// Finished lists the finished chunks, oldest first (by when they were
// written, which a clock gone back doesn't change).
func (s *Segments) Finished() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	names := chunks(s.Spool)
	if s.list != "" {
		s.readList()
		finished := names[:0]
		for _, n := range names {
			if s.before[n] || s.done[filepath.Base(n)] {
				finished = append(finished, n)
			}
		}
		names = finished
	}
	// Forget the chunks that are gone (processed), so a recorder running for
	// months doesn't keep every name.
	present := map[string]bool{}
	for _, n := range chunks(s.Spool) {
		present[filepath.Base(n)] = true
	}
	for name := range s.lengths {
		if !present[name] {
			delete(s.lengths, name)
		}
	}
	for name := range s.done {
		if !present[name] {
			delete(s.done, name)
		}
	}
	mtime := map[string]time.Time{}
	for _, n := range names {
		if info, err := os.Stat(n); err == nil {
			mtime[n] = info.ModTime()
		}
	}
	sort.SliceStable(names, func(i, j int) bool {
		if !mtime[names[i]].Equal(mtime[names[j]]) {
			return mtime[names[i]].Before(mtime[names[j]])
		}
		return names[i] < names[j]
	})
	return names
}

// readList reads the segment list's new lines. Callers hold mu.
func (s *Segments) readList() {
	f, err := os.Open(s.list)
	if err != nil {
		return
	}
	defer f.Close()
	if _, err := f.Seek(s.read, 0); err != nil {
		return
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return
	}
	// Only whole lines: ffmpeg may be writing the next.
	end := bytes.LastIndexByte(data, '\n')
	if end < 0 {
		return
	}
	s.read += int64(end + 1)
	for _, line := range strings.Split(string(data[:end]), "\n") {
		fields := strings.Split(line, ",")
		if len(fields) < 3 {
			continue
		}
		name := filepath.Base(strings.Trim(fields[0], `"`))
		s.done[name] = true
		start, err1 := strconv.ParseFloat(fields[1], 64)
		end, err2 := strconv.ParseFloat(strings.TrimSpace(fields[2]), 64)
		if err1 == nil && err2 == nil && end > start {
			if s.lengths == nil {
				s.lengths = map[string]time.Duration{}
			}
			s.lengths[name] = time.Duration((end - start) * float64(time.Second))
		}
	}
}

// Run records until ctx ends, starting the recorder again (after a
// pause) whenever it stops. Check c.Commands() first: its errors are the
// settings'.
func Run(ctx context.Context, c Config, segments *Segments, logf func(string, ...any)) error {
	if err := os.MkdirAll(c.Spool, 0o700); err != nil {
		return err
	}
	pause := 2 * time.Second
	for {
		started := time.Now()
		c.Run = strconv.FormatInt(started.UnixNano(), 36)
		camera, ffmpeg, err := c.Commands()
		if err != nil {
			return err
		}
		logf("recording: %s", strings.Join(append(camera, ffmpeg...), " "))
		segments.started(c.list())
		err = runOnce(ctx, camera, ffmpeg, c.Log)
		segments.stopped()
		if ctx.Err() != nil {
			return nil
		}
		if time.Since(started) > time.Minute {
			pause = 2 * time.Second
		}
		logf("the recorder stopped (%v); starting it again in %s", err, pause)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(pause):
		}
		pause = min(2*pause, time.Minute)
	}
}

// runOnce runs the pipeline until it ends or ctx does. On ctx's end,
// ffmpeg gets SIGINT, so it finishes the chunk it's writing.
func runOnce(ctx context.Context, camera, ffmpeg []string, log io.Writer) error {
	enc := exec.Command(ffmpeg[0], ffmpeg[1:]...)
	// Chunks are named by their UTC start (-strftime uses the local time).
	enc.Env = append(os.Environ(), "TZ=UTC")
	enc.Stderr = log
	var cam *exec.Cmd
	if camera != nil {
		cam = exec.Command(camera[0], camera[1:]...)
		cam.Stderr = log
		pipe, err := cam.StdoutPipe()
		if err != nil {
			return err
		}
		enc.Stdin = pipe
		if err := cam.Start(); err != nil {
			return err
		}
	}
	if err := enc.Start(); err != nil {
		if cam != nil {
			cam.Process.Kill()
			cam.Wait()
		}
		return err
	}
	done := make(chan error, 1)
	go func() { done <- enc.Wait() }()
	var err error
	select {
	case err = <-done:
	case <-ctx.Done():
		if cam != nil {
			cam.Process.Signal(syscall.SIGTERM)
		}
		enc.Process.Signal(os.Interrupt)
		select {
		case err = <-done:
		case <-time.After(10 * time.Second):
			enc.Process.Kill()
			err = <-done
		}
	}
	if cam != nil {
		cam.Process.Signal(syscall.SIGTERM)
		cerr := make(chan error, 1)
		go func() { cerr <- cam.Wait() }()
		select {
		case <-cerr:
		case <-time.After(5 * time.Second):
			cam.Process.Kill()
			<-cerr
		}
	}
	return err
}
