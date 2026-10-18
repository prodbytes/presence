package main

import (
	"context"
	"crypto/md5"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/detect"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// verifyingBucket is the profile's folder, in memory, checking each copy
// as rclone does (size and MD5); the first upload whose key has corrupt in
// it lands corrupted, so it fails verification and keeps no copy.
type verifyingBucket struct {
	mu      sync.Mutex
	objects map[string][]byte
	puts    map[string]int
	corrupt string
}

func (b *verifyingBucket) Put(_ context.Context, path, key, _ string) error {
	sent, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	got := sent
	if b.corrupt != "" && strings.Contains(key, b.corrupt) {
		b.corrupt = ""
		got = append([]byte("x"), sent[1:]...)
	}
	if md5.Sum(got) != md5.Sum(sent) {
		return errors.New("corrupted on transfer: md5 hash differ")
	}
	b.objects[key] = got
	b.puts[key]++
	return nil
}

func (b *verifyingBucket) Move(_ context.Context, from, to string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	data, ok := b.objects[from]
	if !ok {
		return errors.New("no " + from)
	}
	b.objects[to] = data
	delete(b.objects, from)
	return nil
}

func (b *verifyingBucket) Delete(_ context.Context, key string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.objects, key)
	return nil
}

func (b *verifyingBucket) count(prefix string) (n int, twice bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for key := range b.objects {
		if strings.HasPrefix(key, prefix) {
			n++
		}
	}
	for _, p := range b.puts {
		twice = twice || p > 1
	}
	return n, twice
}

// person finds someone in every clip, and writes its thumbnail.
type person struct{}

func (person) Search(_ []detect.Frame, thumbnail string) (detect.Result, error) {
	os.WriteFile(thumbnail, []byte("jpeg"), 0o600)
	someone := detect.Object{Label: "human", Ms: 0, Score: 0.9}
	return detect.Result{Objects: []detect.Object{someone}, Subject: &someone}, nil
}

// Each fetched camera's clip (Blink's, GoPro's, Reolink's, a USB
// camera's) goes through its camera's pipeline: stored once verified in
// the bucket, then deleted from the device, its spool and incoming folder left empty. An upload that fails
// verification keeps the clip, which goes up at the next try.
func TestFetchedClipsAreDeletedOnceVerified(t *testing.T) {
	for _, kind := range []string{"blink", "gopro", "reolink", "usbcam"} {
		t.Run(kind, func(t *testing.T) {
			state := t.TempDir()
			bucket := &verifyingBucket{objects: map[string][]byte{}, puts: map[string]int{}, corrupt: "ingest/"}
			base := &stream.Streamer{
				Store: bucket, Searcher: person{},
				Keyframes: func(_ context.Context, _, dir string) ([]detect.Frame, error) {
					return []detect.Frame{{Path: filepath.Join(dir, "1.jpg")}}, nil
				},
				Duration: func(context.Context, string) (time.Duration, error) { return 30 * time.Second, nil },
				Key:      make([]byte, 32), ProfileID: "automatic_paranoid_axolotl",
				UserID:      func() string { return "42" },
				ObjectScore: 0.6, Logf: t.Logf,
			}
			ctx, stop := context.WithCancel(context.Background())
			var wg sync.WaitGroup
			defer wg.Wait()
			defer stop()
			spool := filepath.Join(state, "spool", kind)
			p := newCameraPipelines(ctx, base, spool, kind, kind, &wg, func(error) {}, t.Logf)

			incoming := filepath.Join(state, kind+"-incoming", "1")
			os.MkdirAll(incoming, 0o700)
			file := filepath.Join(incoming, "rec-"+kind+"-20261014T120000.mp4")
			os.WriteFile(file, []byte("video"), 0o600)
			if err := p.clip(ctx, cameraRef{DeviceID: "calm_quiet_camera", Name: "Porch"}, file); err != nil {
				t.Fatal(err)
			}
			// The first upload fails verification: the clip waits 5 s for
			// the next try.
			deadline := time.Now().Add(20 * time.Second)
			for {
				events, _ := bucket.count("events/")
				left, _ := filepath.Glob(filepath.Join(spool, "calm_quiet_camera", "*"))
				if events == 1 && len(left) == 0 {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("events %d, left %v", events, left)
				}
				time.Sleep(50 * time.Millisecond)
			}
			if media, twice := bucket.count("media/"); media != 2 || twice {
				t.Fatalf("media %d, an upload twice %v", media, twice)
			}
			if n, _ := bucket.count("ingest/"); n != 0 {
				t.Fatal("left in ingest")
			}
			// Its events name the camera beside its device, and say it's one.
			bucket.mu.Lock()
			for key, data := range bucket.objects {
				if !strings.HasPrefix(key, "events/") {
					continue
				}
				var event map[string]any
				json.Unmarshal(data, &event)
				if event["cameraName"] != "Porch" || event["detail"] != "Porch" ||
					event["deviceId"] != "calm_quiet_camera" || event["os"] != kind || event["cameraId"] != kind {
					t.Errorf("event %v", event)
				}
			}
			bucket.mu.Unlock()
			if left, _ := os.ReadDir(incoming); len(left) != 0 {
				t.Fatalf("left in incoming: %v", left)
			}
		})
	}
}
