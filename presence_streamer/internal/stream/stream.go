// Package stream takes each recorded chunk through ingest and
// recognition:
//
//  1. sealed with the device's key and uploaded to the profile's ingest
//     prefix (`ingest/<deviceId>/<clipId>.mp4`), so it's off the Pi;
//  2. searched for people and animals, on its keyframes;
//  3. with none, deleted, here and in ingest; with one, moved (server
//     side) to `media/<clipId>.mp4`, with its sealed thumbnail, clip record
//     and event (last, so the event shows once its media is there), as a
//     phone stores a motion clip.
//
// Each chunk's progress is kept beside it (`<chunk>.json`), so a chunk
// interrupted by a restart or a network outage carries on where it was,
// with the same IDs, and nothing is uploaded twice.
//
// Every upload and move is verified (size and MD5: the Store's nil error,
// see the rclone package) before it's noted, and a local file is deleted
// only once what it was for is verified in the bucket: the sealed
// thumbnail and JSON records at once, the sealed copy once the recording
// is in media/ (or, in the cloud's mode, in ingest), the chunk and its
// progress once the chunk is done. A failed verification is a failed
// upload: the files stay, and it's tried again.
package stream

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"sync/atomic"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/detect"
	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/recorder"
	"github.com/prodbytes/presence/presence_streamer/internal/records"
	"github.com/prodbytes/presence/presence_streamer/internal/seal"
)

// maxFailures is how many times a chunk's search may fail before the chunk
// is given up.
const maxFailures = 3

// Store is the profile's folder in the bucket. Put and Move succeed only
// once the object is verified in the bucket, whole (its size and MD5).
type Store interface {
	Put(ctx context.Context, path, key, contentType string) error
	Move(ctx context.Context, from, to string) error
	Delete(ctx context.Context, key string) error
}

// Searcher finds people and animals on frames.
type Searcher interface {
	Search(frames []detect.Frame, thumbnail string) (detect.Result, error)
}

// Streamer processes the spool's chunks.
type Streamer struct {
	Spool    string
	Store    Store
	Searcher Searcher
	// Keyframes decodes a chunk's keyframes into a folder; Duration says
	// how long a chunk is (an error: it's broken).
	Keyframes func(ctx context.Context, chunk, dir string) ([]detect.Frame, error)
	Duration  func(ctx context.Context, chunk string) (time.Duration, error)
	// Length is a chunk's length as the recorder listed it, if it did
	// (then Duration isn't needed).
	Length func(chunk string) (time.Duration, bool)
	// Motion is a chunk's motion, in percent (detect.Motion); MotionMin the
	// least it must have to be uploaded (0: every chunk is).
	Motion    func(ctx context.Context, chunk string) (float64, error)
	MotionMin float64

	Key       []byte
	DeviceID  string
	ProfileID string
	UserID    func() string
	Camera    records.Camera
	Location  *records.Location
	// ObjectScore is the least score an object tag needs (the app's 0.6).
	ObjectScore float64
	// MaxSpool is the most the spool may hold, in bytes; the oldest chunks
	// go first beyond it (when the network is down for long).
	MaxSpool int64
	Logf     func(string, ...any)
	// Stored is called with each event stored (tests).
	Stored func(records.Event)
	// Cloud sends chunks to the cloud detector instead of searching them
	// here (a Pi with too little memory): each chunk is uploaded to ingest
	// with its job, and deleted here.
	Cloud bool

	// settingsUp is whether the device's settings (its media key) are in
	// the bucket: the cloud detector needs them to open its chunks.
	settingsUp atomic.Bool
}

// errSettingsPending holds the cloud's chunks back until the settings are up.
var errSettingsPending = errors.New("the device's settings (its media key) aren't uploaded yet")

// progress is a chunk's progress, kept in <chunk>.json.
type progress struct {
	ClipID   string         `json:"clipId"`
	EventID  string         `json:"eventId"`
	Ingested bool           `json:"ingested"`
	LengthMs int64          `json:"lengthMs,omitempty"`
	Motion   *float64       `json:"motion,omitempty"`
	Failures int            `json:"failures,omitempty"`
	Result   *detect.Result `json:"result,omitempty"`
	Moved    bool           `json:"moved,omitempty"`
	Thumb    bool           `json:"thumb,omitempty"`
	Clip     bool           `json:"clip,omitempty"`
	// Event (here) or Job (the cloud's mode): the last upload done, so a
	// restart before the chunk's deleted deletes it without uploading it
	// again.
	Event bool `json:"event,omitempty"`
	Job   bool `json:"job,omitempty"`
}

func load(path string, start time.Time) (*progress, error) {
	p := &progress{}
	data, err := os.ReadFile(path)
	if err == nil {
		if json.Unmarshal(data, p) == nil && p.ClipID != "" {
			return p, nil
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	p = &progress{ClipID: ids.NewEvent(start), EventID: ids.NewEvent(start)}
	return p, save(path, p)
}

func save(path string, p *progress) error {
	data, _ := json.Marshal(p)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// remove deletes a chunk and everything made from it.
func remove(chunk string) {
	for _, p := range []string{chunk, chunk + ".json", chunk + ".json.tmp", chunk + ".sealed", chunk + ".jpg", chunk + ".jpg.sealed",
		chunk + ".clip.json", chunk + ".event.json", chunk + ".job.json"} {
		os.Remove(p)
	}
	os.RemoveAll(chunk + ".frames")
}

// Process takes one finished chunk through ingest and recognition. An
// error leaves it, and its progress, to be tried again.
func (s *Streamer) Process(ctx context.Context, chunk string) error {
	start, ok := recorder.StartOf(chunk)
	if !ok {
		return fmt.Errorf("%s isn't a chunk", chunk)
	}
	name := filepath.Base(chunk)
	p, err := load(chunk+".json", start)
	if err != nil {
		return err
	}
	ingest := records.IngestKey(s.DeviceID, p.ClipID)
	// No motion, nothing to keep: deleted here, before it costs an upload
	// (and S3's storage).
	if s.MotionMin > 0 && !p.Ingested && p.Motion == nil {
		motion, err := s.Motion(ctx, chunk)
		if errors.Is(err, detect.ErrBroken) {
			s.Logf("%s: broken, deleted (%v)", name, err)
			remove(chunk)
			return nil
		}
		if err != nil {
			return err
		}
		if motion <= s.MotionMin {
			s.Logf("%s: no motion (%.1f%%), deleted", name, motion)
			remove(chunk)
			return nil
		}
		p.Motion = &motion
		if err := save(chunk+".json", p); err != nil {
			return err
		}
	}
	if s.Length != nil && p.LengthMs == 0 {
		if length, ok := s.Length(chunk); ok {
			p.LengthMs = max(length.Milliseconds(), 1)
		}
	}
	if p.LengthMs == 0 {
		length, err := s.Duration(ctx, chunk)
		if errors.Is(err, detect.ErrBroken) && !p.Ingested {
			// Cut off (a power cut, the recorder killed): nothing to keep.
			s.Logf("%s: broken, deleted (%v)", name, err)
			remove(chunk)
			return nil
		}
		if err != nil {
			return err
		}
		p.LengthMs = max(length.Milliseconds(), 1)
		if err := save(chunk+".json", p); err != nil {
			return err
		}
	}
	length := time.Duration(p.LengthMs) * time.Millisecond

	if s.Cloud && !s.settingsUp.Load() {
		return errSettingsPending
	}
	if !p.Ingested {
		if err := seal.File(chunk, chunk+".sealed", s.Key, s.DeviceID); err != nil {
			return fmt.Errorf("sealing %s: %w", name, err)
		}
		if err := s.Store.Put(ctx, chunk+".sealed", ingest, "application/octet-stream"); err != nil {
			return fmt.Errorf("uploading %s to ingest: %w", name, err)
		}
		// Here, the sealed copy stays until the recording is in media/: a
		// move there that fails can upload it instead.
		p.Ingested = true
		if err := save(chunk+".json", p); err != nil {
			return err
		}
	}

	if s.Cloud {
		// Verified in ingest, and the cloud's from here: the sealed copy
		// isn't needed.
		os.Remove(chunk + ".sealed")
		// The cloud detector takes it from here: the job, uploaded after
		// the chunk, is what it's called for.
		if !p.Job {
			event, clip := records.ClipOf(records.Chunk{Start: start, Duration: length},
				p.EventID, p.ClipID, s.Camera, s.DeviceID, s.UserID(), s.ProfileID, s.Location)
			job := records.Job{V: 1, Event: event, Clip: clip}
			if err := s.putJSON(ctx, chunk+".job.json", records.JobKey(s.DeviceID, p.ClipID), job); err != nil {
				return fmt.Errorf("uploading %s's job: %w", name, err)
			}
			p.Job = true
			if err := save(chunk+".json", p); err != nil {
				return err
			}
		}
		s.Logf("%s: uploaded for the cloud detector, deleted here", name)
		remove(chunk)
		return nil
	}

	if p.Result == nil {
		frames := chunk + ".frames"
		os.RemoveAll(frames)
		if err := os.MkdirAll(frames, 0o700); err != nil {
			return err
		}
		list, err := s.Keyframes(ctx, chunk, frames)
		var result detect.Result
		if err == nil {
			result, err = s.Searcher.Search(list, chunk+".jpg")
		}
		os.RemoveAll(frames)
		if err != nil {
			// A chunk the detector or ffmpeg keeps failing on would hold
			// up every chunk after it: after 3 tries it's given up. Not when
			// the detector can't start, or the search was stopped.
			if ctx.Err() == nil && !errors.Is(err, detect.ErrUnavailable) {
				p.Failures++
				if p.Failures >= maxFailures {
					s.Logf("%s: couldn't search it %d times (%v): deleted", name, p.Failures, err)
					if err := s.Store.Delete(ctx, ingest); err != nil {
						s.Logf("%s: couldn't delete it from ingest: %v", name, err)
					}
					remove(chunk)
					return nil
				}
				if err := save(chunk+".json", p); err != nil {
					return err
				}
			}
			return fmt.Errorf("searching %s: %w", name, err)
		}
		p.Result = &result
		if err := save(chunk+".json", p); err != nil {
			return err
		}
	}

	if p.Result.Subject == nil {
		if err := s.Store.Delete(ctx, ingest); err != nil {
			// Already gone (an earlier try), or the network: the bucket's
			// lifecycle erases what's left (365 days).
			s.Logf("%s: couldn't delete it from ingest: %v", name, err)
		}
		s.Logf("%s: no one there, deleted", name)
		remove(chunk)
		return nil
	}

	if !p.Thumb {
		if _, err := os.Stat(chunk + ".jpg"); err == nil {
			if err := seal.File(chunk+".jpg", chunk+".jpg.sealed", s.Key, s.DeviceID); err != nil {
				return fmt.Errorf("sealing %s's thumbnail: %w", name, err)
			}
			if err := s.Store.Put(ctx, chunk+".jpg.sealed", records.ThumbnailKey(p.ClipID), "application/octet-stream"); err != nil {
				return fmt.Errorf("uploading %s's thumbnail: %w", name, err)
			}
		}
		p.Thumb = true
		if err := save(chunk+".json", p); err != nil {
			return err
		}
	}
	// The thumbnail's verified in media/ (or there was none).
	os.Remove(chunk + ".jpg")
	os.Remove(chunk + ".jpg.sealed")
	if !p.Moved {
		if err := s.Store.Move(ctx, ingest, records.RecordingKey(p.ClipID)); err != nil {
			// Moved already, before a crash kept it from being noted, or
			// lost from ingest: the sealed copy goes up instead.
			if _, serr := os.Stat(chunk + ".sealed"); serr != nil {
				return fmt.Errorf("moving %s to media: %w", name, err)
			}
			if err := s.Store.Put(ctx, chunk+".sealed", records.RecordingKey(p.ClipID), "application/octet-stream"); err != nil {
				return fmt.Errorf("uploading %s to media: %w", name, err)
			}
			if err := s.Store.Delete(ctx, ingest); err != nil {
				s.Logf("%s: couldn't delete it from ingest: %v", name, err)
			}
		}
		p.Moved = true
		if err := save(chunk+".json", p); err != nil {
			return err
		}
	}
	// The recording's verified in media/.
	os.Remove(chunk + ".sealed")

	var tags []records.ObjectTag
	for _, o := range p.Result.Objects {
		if o.Score >= s.ObjectScore {
			tags = append(tags, records.ObjectTag{Label: o.Label, Ms: o.Ms, Score: o.Score})
		}
	}
	// The subject counts at its own (lower) threshold, so the event's
	// tags always name who made it worth keeping.
	sub := p.Result.Subject
	if !hasLabel(tags, sub.Label) {
		tags = append(tags, records.ObjectTag{Label: sub.Label, Ms: sub.Ms, Score: sub.Score})
	}
	sort.Slice(tags, func(i, j int) bool { return tags[i].Label < tags[j].Label })
	event, clip := records.ClipOf(records.Chunk{Start: start, Duration: length, Tags: tags},
		p.EventID, p.ClipID, s.Camera, s.DeviceID, s.UserID(), s.ProfileID, s.Location)

	if !p.Clip {
		if err := s.putJSON(ctx, chunk+".clip.json", records.ClipKey(clip), clip); err != nil {
			return fmt.Errorf("uploading %s's clip record: %w", name, err)
		}
		p.Clip = true
		if err := save(chunk+".json", p); err != nil {
			return err
		}
	}
	if !p.Event {
		if err := s.putJSON(ctx, chunk+".event.json", records.EventKey(event), event); err != nil {
			return fmt.Errorf("uploading %s's event: %w", name, err)
		}
		p.Event = true
		if err := save(chunk+".json", p); err != nil {
			return err
		}
		if s.Stored != nil {
			s.Stored(event)
		}
	}
	// Everything's verified in the bucket: nothing of it stays here.
	s.Logf("%s: %s (%.2f), stored as event %s, deleted here", name, sub.Label, sub.Score, event.ID)
	remove(chunk)
	return nil
}

func hasLabel(tags []records.ObjectTag, label string) bool {
	for _, t := range tags {
		if t.Label == label {
			return true
		}
	}
	return false
}

func (s *Streamer) putJSON(ctx context.Context, path, key string, record any) error {
	if err := os.WriteFile(path, records.JSON(record), 0o600); err != nil {
		return err
	}
	if err := s.Store.Put(ctx, path, key, "application/json"); err != nil {
		return err
	}
	// Verified in the bucket.
	os.Remove(path)
	return nil
}

// Settings uploads the device's settings record, with its media key, so
// the profile's other devices open what it uploads.
func (s *Streamer) Settings(ctx context.Context, now time.Time) error {
	path := filepath.Join(s.Spool, "settings.json")
	defer os.Remove(path)
	err := s.putJSON(ctx, path, records.SettingsKey(s.DeviceID), records.Settings{
		DeviceID:  s.DeviceID,
		ProfileID: s.ProfileID,
		UpdatedAt: now.UnixMilli(),
		Config:    map[string]any{"version": 1},
		Location:  s.Location,
		MediaKey:  base64.StdEncoding.EncodeToString(s.Key),
	})
	if err == nil {
		s.settingsUp.Store(true)
	}
	return err
}

// Trim deletes the oldest of the finished chunks while the spool holds
// more than MaxSpool.
func (s *Streamer) Trim(chunks []string) {
	if s.MaxSpool <= 0 {
		return
	}
	var total int64
	_ = filepath.WalkDir(s.Spool, func(_ string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			if info, err := d.Info(); err == nil {
				total += info.Size()
			}
		}
		return nil
	})
	for _, chunk := range chunks {
		if total <= s.MaxSpool {
			return
		}
		var size int64
		for _, suffix := range []string{"", ".sealed"} {
			if info, err := os.Stat(chunk + suffix); err == nil {
				size += info.Size()
			}
		}
		s.Logf("%s: the spool is full (%d MB), deleted unsent", filepath.Base(chunk), total>>20)
		remove(chunk)
		total -= size
	}
}

// Run processes finished chunks as they come (finished lists them, oldest
// first) until ctx ends. A chunk that fails is tried again after a pause
// that doubles with each failure in a row (5 s to 2 min). fatal stops it.
func (s *Streamer) Run(ctx context.Context, finished func() []string, fatal func(error) bool) error {
	pause := 5 * time.Second
	for {
		s.Trim(finished())
		chunks := finished()
		var failed error
		for _, chunk := range chunks {
			if ctx.Err() != nil {
				return nil
			}
			if err := s.Process(ctx, chunk); err != nil {
				if fatal(err) {
					return err
				}
				failed = err
				break
			}
		}
		wait := 2 * time.Second
		if failed != nil {
			if ctx.Err() == nil {
				s.Logf("%v; trying again in %s", failed, pause)
			}
			wait = pause
			pause = min(2*pause, 2*time.Minute)
		} else {
			pause = 5 * time.Second
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(wait):
		}
	}
}
