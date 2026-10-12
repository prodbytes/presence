// presence-streamer makes a Raspberry Pi a Presence camera without a
// screen: it records the camera continuously, uploads each chunk to the
// profile's ingest folder, and keeps the chunks with a person or an animal
// in them as events, as a phone would. Only premium profiles: a free one
// ends it. See specs/streamer.md.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"os/user"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/detect"
	"github.com/prodbytes/presence/presence_streamer/internal/google"
	"github.com/prodbytes/presence/presence_streamer/internal/ids"
	"github.com/prodbytes/presence/presence_streamer/internal/presence"
	"github.com/prodbytes/presence/presence_streamer/internal/rclone"
	"github.com/prodbytes/presence/presence_streamer/internal/recorder"
	"github.com/prodbytes/presence/presence_streamer/internal/records"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/state"
	"github.com/prodbytes/presence/presence_streamer/internal/stream"
)

// Set at build time (-ldflags -X): the version, and the Google OAuth
// client ("TVs and Limited Input devices") the device sign-in uses.
var (
	version            = "dev"
	googleClientID     = ""
	googleClientSecret = ""
)

// Exit codes: the service doesn't restart for usage (2) or a free
// profile (3).
const (
	exitError = 1
	exitUsage = 2
	exitFree  = 3
)

type options struct {
	profile, stateDir, api, bucket, endpoint, clientID, clientSecret   string
	key, deviceID                                                      string
	source, device, encoder, cameraLabel, location, bwlimit, detection string
	width, height, fps, bitrate, rotation, spoolMaxMB, threads         int
	motionMin                                                          float64
	chunk                                                              time.Duration
	detector, models, python, rclone, ffmpeg, ffprobe, rpicam          string
}

// env is the PRESENCE_STREAMER_<name> setting, or def.
func env(name, def string) string {
	if v, ok := os.LookupEnv("PRESENCE_STREAMER_" + name); ok && v != "" {
		return v
	}
	return def
}

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(env(name, "")); err == nil {
		return v
	}
	return def
}

// beside is the first of names that exists next to the executable, or in
// the package's folders, else the last.
func beside(names ...string) string {
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		for _, n := range names {
			if !filepath.IsAbs(n) {
				if _, err := os.Stat(filepath.Join(dir, n)); err == nil {
					return filepath.Join(dir, n)
				}
			}
		}
	}
	for _, n := range names {
		if filepath.IsAbs(n) {
			if _, err := os.Stat(n); err == nil {
				return n
			}
		}
	}
	return names[len(names)-1]
}

// serviceHome is the package's state folder, the service user's home.
const serviceHome = "/var/lib/presence-streamer"

// serviceUser is the user the package's service runs as.
const serviceUser = "presence-streamer"

func defaultStateDir() string {
	if dir := env("STATE_DIR", ""); dir != "" {
		return dir
	}
	// The package's folder, when this user may write it (the service user).
	if syscall.Access(serviceHome, 2 /* W_OK */) == nil && os.Geteuid() != 0 {
		return serviceHome
	}
	if os.Geteuid() != 0 {
		if home, err := os.UserHomeDir(); err == nil {
			if base := os.Getenv("XDG_STATE_HOME"); base != "" {
				return filepath.Join(base, "presence-streamer")
			}
			return filepath.Join(home, ".local", "state", "presence-streamer")
		}
	}
	return serviceHome
}

// asServiceUser runs this command again as the package's service user,
// when root runs it and the package is installed, so the state it writes
// is the service's. After a setup it turns the service on, for every boot.
// It answers false when it doesn't apply.
func asServiceUser(command string, args []string) (int, bool) {
	if os.Geteuid() != 0 || os.Getenv("PRESENCE_STREAMER_STATE_DIR") != "" {
		return 0, false
	}
	if _, err := user.Lookup(serviceUser); err != nil {
		return 0, false
	}
	runuser, err := exec.LookPath("runuser")
	if err != nil {
		return 0, false
	}
	exe, err := os.Executable()
	if err != nil {
		return 0, false
	}
	cmd := exec.Command(runuser, append([]string{"-u", serviceUser, "--", exe, command}, args...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), "PRESENCE_STREAMER_STATE_DIR="+serviceHome)
	if err := cmd.Run(); err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			return exit.ExitCode(), true
		}
		log.Print(err)
		return exitError, true
	}
	if command == "setup" || command == "sign-out" {
		if systemctl, err := exec.LookPath("systemctl"); err == nil {
			action := []string{"enable", "--now"}
			if command == "sign-out" {
				action = []string{"stop"}
			} else {
				exec.Command(systemctl, "reset-failed", "presence-streamer.service").Run()
			}
			c := exec.Command(systemctl, append(action, "presence-streamer.service")...)
			c.Stdout, c.Stderr = os.Stdout, os.Stderr
			if err := c.Run(); err != nil {
				log.Printf("systemctl %s presence-streamer: %v", action[0], err)
				return exitError, true
			}
			if command == "setup" {
				exec.Command(systemctl, "restart", "presence-streamer.service").Run()
				fmt.Println("The streamer is on, and starts at every boot: journalctl -fu presence-streamer to follow it.")
			}
		}
	}
	return 0, true
}

func parse(name string, args []string) (*options, *flag.FlagSet) {
	o := &options{}
	fs := flag.NewFlagSet("presence-streamer "+name, flag.ExitOnError)
	fs.StringVar(&o.profile, "profile", env("PROFILE", ""), "the profile to stream to (default: the saved one, else the signed-in account's)")
	fs.StringVar(&o.key, "key", env("KEY", ""), "the device's stream key (psk_…), from the command in the app's profile view: no Google sign-in")
	fs.StringVar(&o.deviceID, "device-id", env("DEVICE_ID", ""), "this device's ID in the profile (default: the saved one, else a new one)")
	fs.StringVar(&o.stateDir, "state-dir", defaultStateDir(), "where the device ID, key, sign-in and spool are kept")
	fs.StringVar(&o.api, "api", env("API", "https://presence.nu01.com"), "the Presence site (its auth API)")
	fs.StringVar(&o.bucket, "bucket", env("BUCKET", ""), "the user-data bucket, when the auth API doesn't name it")
	fs.StringVar(&o.endpoint, "s3-endpoint", env("S3_ENDPOINT", ""), "another S3 endpoint (testing); empty is AWS")
	fs.StringVar(&o.clientID, "google-client-id", env("GOOGLE_CLIENT_ID", googleClientID), "the Google OAuth client for device sign-in")
	fs.StringVar(&o.clientSecret, "google-client-secret", env("GOOGLE_CLIENT_SECRET", googleClientSecret), "its secret (not confidential for this kind of client)")
	fs.StringVar(&o.source, "source", env("SOURCE", "auto"), "auto, libcamera (camera module), v4l2 (USB) or test")
	fs.StringVar(&o.device, "device", env("DEVICE", ""), "the v4l2 device (default /dev/video0), or test's video file")
	fs.StringVar(&o.encoder, "encoder", env("ENCODER", "auto"), "auto, hw (the Pi's H.264 encoder) or sw")
	motionMin, err := strconv.ParseFloat(env("MOTION_MIN", "5"), 64)
	if err != nil {
		motionMin = 5
	}
	fs.Float64Var(&o.motionMin, "motion-min", motionMin, "the least motion (percent of the picture changed, as the app measures it) a chunk needs to be uploaded; 0 uploads every chunk")
	fs.StringVar(&o.detection, "detection", env("DETECTION", "auto"), "where chunks are searched for people and animals: auto (here with 2 GB of memory or more, else in the cloud), local or cloud")
	fs.IntVar(&o.width, "width", envInt("WIDTH", 1280), "video width")
	fs.IntVar(&o.height, "height", envInt("HEIGHT", 720), "video height")
	fs.IntVar(&o.fps, "fps", envInt("FPS", 30), "frames per second")
	fs.IntVar(&o.bitrate, "bitrate", envInt("BITRATE", 2500000), "video bit rate, bits/s")
	fs.IntVar(&o.rotation, "rotation", envInt("ROTATION", 0), "0 or 180 (camera module)")
	chunk, err := time.ParseDuration(env("CHUNK", "30s"))
	if err != nil {
		chunk = 30 * time.Second
	}
	fs.DurationVar(&o.chunk, "chunk", chunk, "chunk length (10s to 5m)")
	fs.IntVar(&o.spoolMaxMB, "spool-max-mb", envInt("SPOOL_MAX_MB", 2048), "the most the spool keeps while offline, MB")
	fs.StringVar(&o.bwlimit, "bwlimit", env("BWLIMIT", ""), "rclone's upload bandwidth limit (e.g. 1M)")
	fs.StringVar(&o.cameraLabel, "camera-label", env("CAMERA_LABEL", ""), "the camera's name on events")
	fs.StringVar(&o.location, "location", env("LOCATION", ""), "where the camera is, \"lat,lng\", for the map")
	fs.IntVar(&o.threads, "detector-threads", envInt("DETECTOR_THREADS", 0), "the detector's threads (0: OpenCV's default)")
	fs.StringVar(&o.detector, "detector", env("DETECTOR", beside("presence-detect.py", "/usr/lib/presence-streamer/presence-detect.py")), "the detector script")
	fs.StringVar(&o.models, "models", env("MODELS", beside("models", "/usr/share/presence-streamer/models")), "the detector's models folder")
	fs.StringVar(&o.python, "python", env("PYTHON", "python3"), "python3")
	fs.StringVar(&o.rclone, "rclone", env("RCLONE", "rclone"), "rclone")
	fs.StringVar(&o.ffmpeg, "ffmpeg", env("FFMPEG", "ffmpeg"), "ffmpeg")
	fs.StringVar(&o.ffprobe, "ffprobe", env("FFPROBE", "ffprobe"), "ffprobe")
	fs.StringVar(&o.rpicam, "rpicam-vid", env("RPICAM_VID", recorder.FindRpicamVid()), "rpicam-vid (camera module)")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "Usage: presence-streamer %s [flags]\n\nEvery flag can also be set as PRESENCE_STREAMER_<NAME> (e.g. PRESENCE_STREAMER_PROFILE).\n\n", name)
		fs.PrintDefaults()
	}
	fs.Parse(args)
	return o, fs
}

func usage() {
	fmt.Fprint(os.Stderr, `presence-streamer: streams a Raspberry Pi camera to a Presence profile.

Usage:
  presence-streamer [run] [flags]  sign in if needed, and stream to the profile
  presence-streamer setup --profile P --device-id D --key K
                                   set up with the command from the app's
                                   profile view (no sign-in), then exit
  presence-streamer setup [flags]  or sign in with Google (a code), then exit
  presence-streamer status         the profile, device and sign-in
  presence-streamer sign-out       forget the Google sign-in
  presence-streamer version

Run "presence-streamer run -h" for the flags.
`)
}

func main() {
	log.SetFlags(0)
	args := os.Args[1:]
	command := "run"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		command, args = args[0], args[1:]
	}
	if command == "setup" || command == "status" || command == "sign-out" {
		if code, done := asServiceUser(command, args); done {
			os.Exit(code)
		}
	}
	if command == "run" && os.Geteuid() == 0 && os.Getenv("PRESENCE_STREAMER_STATE_DIR") == "" {
		if _, err := user.Lookup(serviceUser); err == nil {
			log.Print("the service runs the streamer: sudo systemctl start presence-streamer (and sudo presence-streamer setup to set it up)")
			os.Exit(exitUsage)
		}
	}
	switch command {
	case "run", "setup":
		o, _ := parse(command, args)
		os.Exit(run(o, command == "setup"))
	case "status":
		o, _ := parse(command, args)
		os.Exit(status(o))
	case "sign-out":
		o, _ := parse(command, args)
		s, err := state.Load(o.stateDir)
		if err != nil {
			log.Print(err)
			os.Exit(exitError)
		}
		if err := s.SignOut(); err != nil {
			log.Print(err)
			os.Exit(exitError)
		}
		fmt.Println("Signed out.")
	case "version", "--version", "-version":
		fmt.Printf("presence-streamer %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH)
	case "help", "-h", "--help":
		usage()
	default:
		usage()
		os.Exit(exitUsage)
	}
}

func status(o *options) int {
	s, err := state.Load(o.stateDir)
	if err != nil {
		log.Print(err)
		return exitError
	}
	signedIn := "not signed in"
	switch {
	case s.StreamKey != "":
		signedIn = "none: the device's stream key"
	case s.RefreshToken != "":
		signedIn = "signed in as " + s.Email
	}
	fmt.Printf("profile: %s\ndevice:  %s\nGoogle:  %s\nstate:   %s\n", orNone(s.ProfileID), s.DeviceID, signedIn, o.stateDir)
	return 0
}

func orNone(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}

// terminal is the controlling terminal, for the sign-in's code; nil when
// there's none (a service).
func terminal() *os.File {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return nil
	}
	return tty
}

// chooseProfile is the profile to stream to: --profile (or
// PRESENCE_STREAMER_PROFILE), else the one saved. Empty when neither is
// set: then it's the signed-in account's own, fetched after the sign-in.
func chooseProfile(o *options, s *state.State) (string, error) {
	profile := o.profile
	if profile == "" {
		profile = s.ProfileID
	}
	if profile != "" && (!ids.ProfilePattern.MatchString(profile) || len(profile) > 64) {
		return "", fmt.Errorf("%q isn't a profile ID (they look like automatic_paranoid_axolotl)", profile)
	}
	return profile, nil
}

// signIn signs in with Google's device flow, on the terminal.
func signIn(ctx context.Context, g *google.Client, tty *os.File) (google.Tokens, error) {
	code, err := g.RequestCode(ctx)
	if err != nil {
		return google.Tokens{}, err
	}
	fmt.Fprintf(tty, "\nSign in with a Google account of the profile:\n\n  1. On your phone or computer, open %s\n  2. Enter the code  %s\n\nWaiting for the sign-in…\n", code.VerificationURL, code.UserCode)
	return g.Wait(ctx, code)
}

func run(o *options, setupOnly bool) int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	logf := log.Printf

	s, err := state.Load(o.stateDir)
	if err != nil {
		log.Print(err)
		return exitError
	}
	// One streamer per state: two would record into the same spool.
	unlock, err := state.Lock(o.stateDir)
	if err != nil {
		log.Print(err)
		return exitUsage
	}
	defer unlock()
	tty := terminal()
	if tty != nil {
		defer tty.Close()
	}
	profile, err := chooseProfile(o, s)
	if err != nil {
		log.Print(err)
		return exitUsage
	}
	if profile != "" && profile != s.ProfileID {
		// Another profile: another account's sign-in, and another key.
		s.ProfileID, s.RefreshToken, s.Email, s.StreamKey = profile, "", "", ""
		if err := s.Save(); err != nil {
			log.Print(err)
			return exitError
		}
	}
	api := &presence.API{BaseURL: o.api}
	if o.key != "" || o.deviceID != "" {
		// The app's command: the device and its key, no Google sign-in.
		if code := takeKey(ctx, o, s, profile, api); code != 0 {
			return code
		}
	}
	if s.StreamKey != "" {
		sess := &session.Session{API: api, StreamKey: s.StreamKey, ProfileID: s.ProfileID, DeviceID: s.DeviceID}
		creds, err := sess.Credentials(ctx)
		if err != nil {
			return exitFor(err, s, logf)
		}
		logf("profile %s (premium), device %s, with its stream key", s.ProfileID, s.DeviceID)
		if setupOnly {
			fmt.Printf("Ready: device %s streams to profile %s.\n", s.DeviceID, s.ProfileID)
			return 0
		}
		return streamCamera(ctx, o, s, sess, creds, logf)
	}

	if o.clientID == "" || o.clientSecret == "" {
		log.Print("no Google OAuth client, and no stream key: copy the command from the app's profile view")
		return exitUsage
	}
	g := &google.Client{ID: o.clientID, Secret: o.clientSecret, Endpoints: google.Google}
	if s.RefreshToken == "" {
		if tty == nil {
			log.Print("not signed in: run presence-streamer setup on a terminal (PRESENCE_STREAMER_PROFILE, or --profile, picks the profile; else it's the account's)")
			return exitUsage
		}
		tokens, err := signIn(ctx, g, tty)
		if err != nil {
			log.Print(err)
			return exitError
		}
		claims, _ := google.ClaimsOf(tokens.IDToken)
		if profile == "" {
			// None given: the account's own.
			if profile, err = api.Profile(ctx, tokens.IDToken); err != nil {
				return exitFor(err, s, logf)
			}
			fmt.Fprintf(tty, "This account's profile is %s.\n", profile)
			s.ProfileID = profile
		}
		// Checked before it's kept: the account must be the profile's, and
		// the profile premium.
		if _, err := session.Check(ctx, api, tokens.IDToken, profile, s.DeviceID); err != nil {
			return exitFor(err, s, logf)
		}
		s.RefreshToken, s.Email = tokens.RefreshToken, claims.Email
		if err := s.Save(); err != nil {
			log.Print(err)
			return exitError
		}
		fmt.Fprintf(tty, "Signed in as %s.\n", claims.Email)
	}

	sess := &session.Session{Google: g, API: api, RefreshToken: s.RefreshToken, ProfileID: profile, DeviceID: s.DeviceID}
	creds, err := sess.Credentials(ctx)
	if err != nil {
		return exitFor(err, s, logf)
	}
	logf("profile %s (premium), device %s, signed in as %s", profile, s.DeviceID, s.Email)
	if setupOnly {
		fmt.Printf("Ready: device %s streams to profile %s.\n", s.DeviceID, profile)
		return 0
	}
	return streamCamera(ctx, o, s, sess, creds, logf)
}

// streamKeyPattern is a stream key as the auth API makes them.
var streamKeyPattern = regexp.MustCompile(`^psk_[A-Za-z0-9_-]{43}$`)

// takeKey keeps the app command's device ID and stream key (--device-id,
// --key) for profile, after checking them with the auth API: the key must
// be the device's, and the profile premium. It answers 0, or the exit code.
func takeKey(ctx context.Context, o *options, s *state.State, profile string, api *presence.API) int {
	key, device := o.key, o.deviceID
	if key == "" {
		key = s.StreamKey
	}
	if device == "" {
		device = s.DeviceID
	}
	switch {
	case profile == "":
		log.Print("a stream key needs its profile: --profile, as in the app's command")
		return exitUsage
	case !streamKeyPattern.MatchString(key):
		log.Print("that isn't a stream key (psk_…): copy the command from the app's profile view")
		return exitUsage
	case !ids.DevicePattern.MatchString(device):
		log.Printf("%q isn't a device ID (they look like calm_quiet_otter)", device)
		return exitUsage
	}
	if _, err := session.CheckKey(ctx, api, key, profile, device); err != nil {
		return exitFor(err, s, log.Printf)
	}
	s.ProfileID, s.DeviceID, s.StreamKey, s.RefreshToken, s.Email = profile, device, key, "", ""
	if err := s.Save(); err != nil {
		log.Print(err)
		return exitError
	}
	fmt.Printf("Device %s of profile %s: its stream key works.\n", device, profile)
	return 0
}

// localDetectionMemory is the least memory (MemTotal) a Pi detects with
// itself: its 2 GB boards report a little less than 2 GiB (some goes to the
// GPU and the kernel), the 1 GB ones under 1 GiB.
const localDetectionMemory = 1536 << 20

// memTotal is the system's memory (MemTotal in /proc/meminfo), or 0 when it
// can't be read.
func memTotal() int64 {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if rest, ok := strings.CutPrefix(line, "MemTotal:"); ok {
			kb, err := strconv.ParseInt(strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(rest), "kB")), 10, 64)
			if err == nil {
				return kb << 10
			}
		}
	}
	return 0
}

// detectInCloud says whether chunks are searched in the cloud, and why:
// mode local or cloud says so; auto decides by the memory (total bytes, 0
// unknown), the cloud below 2 GB (detecting here takes too much of a smaller Pi's memory and CPU).
func detectInCloud(mode string, total int64) (bool, string, error) {
	switch mode {
	case "local":
		return false, "here (--detection local)", nil
	case "cloud":
		return true, "in the cloud (--detection cloud)", nil
	case "auto", "":
		switch {
		case total == 0:
			return false, "here (the memory is unknown)", nil
		case total < localDetectionMemory:
			return true, fmt.Sprintf("in the cloud (%d MB of memory, less than 2 GB)", total>>20), nil
		default:
			return false, fmt.Sprintf("here (%d MB of memory)", total>>20), nil
		}
	}
	return false, "", fmt.Errorf("--detection %q: use auto, local or cloud", mode)
}

// clockSynced says whether the network has set the clock: systemd's
// time sync says so. Without systemd (development), the clock counts as set.
func clockSynced() bool {
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return true
	}
	if _, err := os.Stat("/run/systemd/timesync/synchronized"); err == nil {
		return true
	}
	out, err := exec.Command("timedatectl", "show", "-p", "NTPSynchronized", "--value").Output()
	return err == nil && strings.TrimSpace(string(out)) == "yes"
}

// waitForClock waits for the clock: a Pi has none of its own, and after a
// boot it says the time it was shut down (fake-hwclock) until the network
// sets it, so chunks would be named, and events dated, wrong. It waits
// for the time sync up to 2 minutes (a Pi offline still records), and as
// long as it takes for the clock to say 2026 at least. False if ctx ends.
func waitForClock(ctx context.Context, logf func(string, ...any)) bool {
	deadline := time.Now().Add(2 * time.Minute)
	for waited := false; ; waited = true {
		synced := clockSynced()
		if time.Now().Year() >= 2026 && (synced || time.Now().After(deadline)) {
			if waited && !synced {
				logf("the clock isn't synchronized; recording anyway (it says %s)", time.Now().UTC().Format(time.RFC3339))
			}
			return true
		}
		if !waited {
			logf("waiting for the network to set the clock (it says %s)", time.Now().UTC().Format(time.RFC3339))
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(5 * time.Second):
		}
	}
}

func parseLocation(text string, now time.Time) (*records.Location, error) {
	if text == "" {
		return nil, nil
	}
	lat, lng, ok := strings.Cut(text, ",")
	la, err1 := strconv.ParseFloat(strings.TrimSpace(lat), 64)
	ln, err2 := strconv.ParseFloat(strings.TrimSpace(lng), 64)
	if !ok || err1 != nil || err2 != nil || la < -90 || la > 90 || ln < -180 || ln > 180 {
		return nil, fmt.Errorf("location %q isn't \"lat,lng\"", text)
	}
	return &records.Location{Lat: la, Lng: ln, Source: "map", Time: now.UnixMilli()}, nil
}

func streamCamera(ctx context.Context, o *options, s *state.State, sess *session.Session, creds presence.Credentials, logf func(string, ...any)) int {
	bucket := creds.Bucket
	if o.bucket != "" {
		bucket = o.bucket
	}
	if bucket == "" {
		log.Print("the auth API didn't name the bucket: set PRESENCE_STREAMER_BUCKET")
		return exitUsage
	}
	if !presence.ValidBucket(bucket) {
		log.Printf("%q isn't a bucket name", bucket)
		return exitUsage
	}
	if o.chunk < 10*time.Second || o.chunk > 5*time.Minute {
		log.Printf("--chunk %s: use 10s to 5m", o.chunk)
		return exitUsage
	}
	cloud, why, err := detectInCloud(o.detection, memTotal())
	if err != nil {
		log.Print(err)
		return exitUsage
	}
	tools := []string{o.ffmpeg, o.ffprobe, o.rclone}
	if !cloud {
		tools = append(tools, o.python)
	}
	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			log.Printf("%s isn't installed (sudo apt install ffmpeg rclone python3-opencv)", tool)
			return exitUsage
		}
	}
	location, err := parseLocation(o.location, time.Now())
	if err != nil {
		log.Print(err)
		return exitUsage
	}
	if !waitForClock(ctx, logf) {
		return 0
	}
	key, _ := s.Key()
	spool := filepath.Join(o.stateDir, "spool")
	if err := os.MkdirAll(spool, 0o700); err != nil {
		log.Print(err)
		return exitError
	}
	region, _, _ := strings.Cut(creds.IdentityID, ":")
	rcloneConf := filepath.Join(o.stateDir, "rclone.conf")
	if f, err := os.OpenFile(rcloneConf, os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		f.Close()
	}
	folder := &rclone.Folder{
		Rclone: o.rclone, Config: rcloneConf, Bucket: bucket, Identity: creds.IdentityID, Region: region,
		Endpoint: o.endpoint, BandwidthLimit: o.bwlimit, Credentials: sess.AWS,
	}

	rec := recorder.Config{
		Source: o.source, Device: o.device, Encoder: o.encoder, Width: o.width, Height: o.height,
		FPS: o.fps, Bitrate: o.bitrate, Chunk: o.chunk, Spool: spool, FFmpeg: o.ffmpeg,
		RpicamVid: o.rpicam, Rotation: o.rotation, Log: prefixed("recorder: "),
	}.Resolve()
	if _, _, err := rec.Commands(); err != nil {
		log.Print(err)
		return exitUsage
	}
	label := o.cameraLabel
	if label == "" {
		label = map[string]string{"libcamera": "Raspberry Pi camera", "v4l2": "USB camera", "test": "Test camera"}[rec.Source]
	}
	logf("camera: %s (%s, %s encoder), %dx%d at %d fps, %s chunks", label, rec.Source, rec.Encoder, rec.Width, rec.Height, rec.FPS, rec.Chunk)

	logf("detection: %s", why)

	detectorCmd := []string{o.python, "-I", o.detector,
		"--cfg", filepath.Join(o.models, "yolov4-tiny.cfg"),
		"--weights", filepath.Join(o.models, "yolov4-tiny.weights")}
	if o.threads > 0 {
		detectorCmd = append(detectorCmd, "--threads", strconv.Itoa(o.threads))
	}
	// Started only when a chunk is searched here, so never in the cloud's
	// mode.
	detector := &detect.Detector{Command: detectorCmd, Log: prefixed("detector: ")}
	defer detector.Close()

	segments := &recorder.Segments{Spool: spool}
	st := &stream.Streamer{
		Spool: spool, Store: folder, Searcher: detector, Cloud: cloud,
		Keyframes: func(ctx context.Context, chunk, dir string) ([]detect.Frame, error) {
			return detect.Keyframes(ctx, o.ffmpeg, chunk, dir, time.Second)
		},
		Duration: func(ctx context.Context, chunk string) (time.Duration, error) {
			return detect.Duration(ctx, o.ffprobe, chunk)
		},
		Length: segments.Length,
		Motion: func(ctx context.Context, chunk string) (float64, error) {
			motion, _, err := detect.Motion(ctx, o.ffmpeg, chunk)
			return motion, err
		},
		MotionMin: o.motionMin,
		Key:       key, DeviceID: s.DeviceID, ProfileID: s.ProfileID, UserID: sess.UserID,
		Camera:      records.Camera{ID: rec.Source, Label: label},
		Location:    location,
		ObjectScore: 0.6,
		MaxSpool:    int64(o.spoolMaxMB) << 20,
		Logf:        logf,
	}

	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)

	// The settings record carries the media key; until it's up, the other
	// devices can't open anything, so it's retried until it is.
	go func() {
		for pause := 5 * time.Second; ; pause = min(2*pause, 2*time.Minute) {
			err := st.Settings(ctx, time.Now())
			if err == nil {
				return
			}
			if session.Fatal(err) {
				cancel(err)
				return
			}
			logf("uploading the device's settings: %v; trying again in %s", err, pause)
			select {
			case <-ctx.Done():
				return
			case <-time.After(pause):
			}
		}
	}()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if err := recorder.Run(ctx, rec, segments, logf); err != nil {
			cancel(err)
		}
	}()
	go func() {
		defer wg.Done()
		if err := st.Run(ctx, segments.Finished, session.Fatal); err != nil {
			cancel(err)
		}
	}()
	<-ctx.Done()
	// The detector is stopped at once, so a search under way doesn't hold
	// up the stop.
	detector.Close()
	wg.Wait()
	return exitFor(context.Cause(ctx), s, logf)
}

// exitFor logs why the streamer stopped and gives its exit code.
func exitFor(failure error, s *state.State, logf func(string, ...any)) int {
	var wrong session.WrongProfileError
	switch {
	case failure == nil || errors.Is(failure, context.Canceled):
		logf("stopped")
		return 0
	case errors.Is(failure, session.ErrFree):
		log.Print(failure)
		return exitFree
	case errors.Is(failure, google.ErrRevoked):
		log.Print(failure)
		s.SignOut()
		return exitUsage
	case errors.As(failure, &wrong) || errors.Is(failure, presence.ErrUnauthorized) ||
		errors.Is(failure, presence.ErrKeyRefused):
		// Not better by trying again: someone must run setup.
		log.Print(failure)
		return exitUsage
	default:
		log.Print(failure)
		return exitError
	}
}

// prefixed writes each line to stderr with a prefix.
func prefixed(prefix string) io.Writer {
	r, w := io.Pipe()
	go func() {
		sc := bufio.NewScanner(r)
		sc.Buffer(make([]byte, 64*1024), 1<<20)
		for sc.Scan() {
			log.Print(prefix + sc.Text())
		}
	}()
	return w
}
