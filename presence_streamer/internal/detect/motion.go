package detect

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
)

// Motion frames are the app's (presence_app/lib/motion.dart): 64×48 luma.
const (
	motionWidth  = 64
	motionHeight = 48
	// motionStep is how much a pixel's brightness must change to count as
	// moved, after the median change is taken off (the app's 24/255), in
	// a lit scene. A dark one gets a smaller step (motionStepFor).
	motionStep = 24
	// minMotionStep is the least step, in the darkest scenes: measured on
	// a Pi Zero's camera in a dim room (mean luma 10/255), a still scene's
	// keyframes moved at most 1.7 % with a step of 4, 4.5 % with 3.
	minMotionStep = 4
)

// motionStepFor is the step for frames a and b: a quarter of their mean
// luma, from minMotionStep to motionStep. A person crossing a dim room
// (mean 10/255) changes few pixels by the app's 24/255, so the fixed step
// never saw them there; lit scenes (mean 96/255 or more) keep the app's.
func motionStepFor(a, b []byte) int {
	sum := 0
	for i := range a {
		sum += int(a[i]) + int(b[i])
	}
	return min(max(sum/(2*len(a))/4, minMotionStep), motionStep)
}

// MotionScore is the app's motion score of frame b after frame a (64×48
// luma each): the percentage of pixels whose brightness changed by more
// than 24/255 (less in a dark scene, motionStepFor), once the median
// change (an exposure shift, a light switched on) is taken off every pixel.
func MotionScore(a, b []byte) float64 {
	n := len(a)
	if n == 0 || len(b) != n {
		return 0
	}
	// The median of the signed changes, -255 to 255, from a histogram.
	var hist [511]int
	for i := range n {
		hist[int(b[i])-int(a[i])+255]++
	}
	median, seen := 0, 0
	for d, c := range hist {
		seen += c
		if seen*2 >= n {
			median = d - 255
			break
		}
	}
	step := motionStepFor(a, b)
	moved := 0
	for i := range n {
		d := int(b[i]) - int(a[i]) - median
		if d > step || d < -step {
			moved++
		}
	}
	return float64(moved) * 100 / float64(n)
}

// Motion is a chunk's motion: the highest motion score between its
// consecutive keyframes (one a second, decoded alone, so it's cheap even on
// a Pi Zero), in percent, and how many keyframes it has. A chunk with one
// keyframe has nothing to compare: its motion is 100 (kept). ErrBroken when
// ffmpeg can't read the chunk.
func Motion(ctx context.Context, ffmpeg, chunk string) (float64, int, error) {
	cmd := exec.CommandContext(ctx, ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
		"-skip_frame", "nokey", "-i", chunk,
		"-vf", fmt.Sprintf("scale=%d:%d:flags=area,format=gray", motionWidth, motionHeight),
		"-fps_mode", "passthrough", "-f", "rawvideo", "-")
	var out, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errs
	if err := cmd.Run(); err != nil {
		return 0, 0, ranAndFailed(ctx, fmt.Sprintf("ffmpeg motion of %s: %s", filepath.Base(chunk), strings.TrimSpace(errs.String())), err)
	}
	size := motionWidth * motionHeight
	frames := out.Len() / size
	if frames == 0 {
		return 0, 0, fmt.Errorf("%w: ffmpeg motion of %s: no frames", ErrBroken, filepath.Base(chunk))
	}
	if frames == 1 {
		return 100, 1, nil
	}
	data := out.Bytes()
	best := 0.0
	for i := 1; i < frames; i++ {
		best = max(best, MotionScore(data[(i-1)*size:i*size], data[i*size:(i+1)*size]))
	}
	return best, frames, nil
}
