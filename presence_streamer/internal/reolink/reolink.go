// Package reolink is Reolink's kind of network camera (specs/reolink.md,
// the netcam package): the streamer logs in to each camera (or NVR) with
// its HTTP API (/cgi-bin/api.cgi, over HTTPS) and fetches the recordings it
// made on its SD card or disk, a day's search at a time.
package reolink

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prodbytes/presence/presence_streamer/internal/netcam"
)

// maxDays is the most days a fetch searches back: each day is a search,
// every fetch, while a camera has nothing newer.
const maxDays = 7

// Kind is Reolink's.
type Kind struct {
	// Full fetches the main stream's recordings; otherwise the sub
	// stream's (low resolution), when the camera records it.
	Full bool
}

// Name names its files ("reolink.json").
func (Kind) Name() string { return "reolink" }

// Base is the camera's API: always HTTPS (the password goes with the
// login), an IP address or host name, or https://host[:port].
func (Kind) Base(a netcam.Add) (string, error) {
	if a.Password == "" {
		return "", errors.New("the camera's password is missing")
	}
	return netcam.BaseOf(a.Address, false, "", true)
}

// Login logs in (cmd=Login): the token the session's commands carry.
func (k Kind) Login(ctx context.Context, c *netcam.Conn) (netcam.Session, error) {
	s := &session{kind: k, c: c}
	user := c.Camera.Username
	if user == "" {
		user = "admin"
	}
	var value struct {
		Token struct {
			Name string `json:"name"`
		} `json:"Token"`
	}
	err := s.cmd(ctx, "Login", map[string]any{"User": map[string]any{
		"Version": "0", "userName": user, "password": c.Camera.Password,
	}}, &value)
	var refused *apiError
	if errors.As(err, &refused) {
		return nil, fmt.Errorf("%w (%s)", netcam.ErrRefused, refused.detail)
	}
	if err != nil {
		return nil, err
	}
	if value.Token.Name == "" {
		return nil, errors.New("the camera gave no token")
	}
	s.token = value.Token.Name
	return s, nil
}

type session struct {
	kind  Kind
	c     *netcam.Conn
	token string
}

// apiError is a command the camera answered with an error.
type apiError struct {
	cmd, detail string
	code        int
}

func (e *apiError) Error() string {
	return fmt.Sprintf("%s: %s (%d)", e.cmd, e.detail, e.code)
}

func (s *session) url(cmd string, query url.Values) string {
	if query == nil {
		query = url.Values{}
	}
	query.Set("cmd", cmd)
	if s.token != "" {
		query.Set("token", s.token)
	}
	return s.c.Camera.Base + "/cgi-bin/api.cgi?" + query.Encode()
}

// cmd runs one command (POST [{"cmd", "action", "param"}]) and decodes its
// value into v.
func (s *session) cmd(ctx context.Context, cmd string, param, v any) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	body, _ := json.Marshal([]any{map[string]any{"cmd": cmd, "action": 0, "param": param}})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.url(cmd, nil), bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.c.Do(req)
	if err != nil {
		return err
	}
	var answers []struct {
		Code  int             `json:"code"`
		Value json.RawMessage `json:"value"`
		Error struct {
			Detail  string `json:"detail"`
			RspCode int    `json:"rspCode"`
		} `json:"error"`
	}
	if err := netcam.JSON(resp, &answers); err != nil {
		return fmt.Errorf("%s: %w", cmd, err)
	}
	if len(answers) == 0 {
		return fmt.Errorf("%s: no answer", cmd)
	}
	a := answers[0]
	if a.Code != 0 {
		return &apiError{cmd: cmd, detail: a.Error.Detail, code: a.Error.RspCode}
	}
	if v == nil {
		return nil
	}
	return json.Unmarshal(a.Value, v)
}

// stamp is the API's time: the camera's local time.
type stamp struct {
	Year int `json:"year"`
	Mon  int `json:"mon"`
	Day  int `json:"day"`
	Hour int `json:"hour"`
	Min  int `json:"min"`
	Sec  int `json:"sec"`
}

func (t stamp) time() time.Time {
	return time.Date(t.Year, time.Month(t.Mon), t.Day, t.Hour, t.Min, t.Sec, 0, time.UTC)
}

func stampOf(t time.Time) stamp {
	return stamp{t.Year(), int(t.Month()), t.Day(), t.Hour(), t.Minute(), t.Second()}
}

// Now is the camera's clock (cmd=GetTime).
func (s *session) Now(ctx context.Context) (time.Time, bool) {
	var value struct {
		Time stamp `json:"Time"`
	}
	if s.cmd(ctx, "GetTime", map[string]any{}, &value) != nil || value.Time.Year == 0 {
		return time.Time{}, false
	}
	return value.Time.time(), true
}

// Videos searches each day since since (cmd=Search, the camera's channel):
// the sub stream's recordings, or the main stream's when there are none
// (or Full).
func (s *session) Videos(ctx context.Context, since int64) ([]netcam.Video, error) {
	now, ok := s.Now(ctx)
	if !ok {
		return nil, errors.New("the camera's clock couldn't be read")
	}
	from := time.Unix(since+1, 0).UTC()
	if first := now.AddDate(0, 0, -maxDays); from.Before(first) {
		from = first
	}
	var out []netcam.Video
	for day := from.Truncate(24 * time.Hour); !day.After(now); day = day.AddDate(0, 0, 1) {
		start := day
		if start.Before(from) {
			start = from
		}
		end := day.Add(24*time.Hour - time.Second)
		var files []netcam.Video
		var err error
		if !s.kind.Full {
			files, err = s.search(ctx, "sub", start, end)
		}
		if err == nil && len(files) == 0 {
			files, err = s.search(ctx, "main", start, end)
		}
		if err != nil {
			return nil, err
		}
		for _, f := range files {
			if f.Created > since {
				out = append(out, f)
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Created < out[j].Created })
	return out, nil
}

func (s *session) search(ctx context.Context, stream string, start, end time.Time) ([]netcam.Video, error) {
	var value struct {
		SearchResult struct {
			File []struct {
				Name      string          `json:"name"`
				Size      json.RawMessage `json:"size"`
				StartTime stamp           `json:"StartTime"`
			} `json:"File"`
		} `json:"SearchResult"`
	}
	err := s.cmd(ctx, "Search", map[string]any{"Search": map[string]any{
		"channel": s.c.Camera.Channel, "onlyStatus": 0, "streamType": stream,
		"StartTime": stampOf(start), "EndTime": stampOf(end),
	}}, &value)
	if err != nil {
		return nil, err
	}
	var out []netcam.Video
	for _, f := range value.SearchResult.File {
		if f.Name == "" || !strings.EqualFold(path.Ext(f.Name), ".mp4") || f.StartTime.Year == 0 {
			continue
		}
		size, _ := strconv.ParseInt(strings.Trim(string(f.Size), `"`), 10, 64)
		out = append(out, netcam.Video{ID: f.Name, Created: f.StartTime.time().Unix(), Size: size})
	}
	return out, nil
}

// Open downloads a recording (cmd=Download).
func (s *session) Open(ctx context.Context, v netcam.Video) (io.ReadCloser, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		s.url("Download", url.Values{"source": {v.ID}, "output": {path.Base(v.ID)}}), nil)
	if err != nil {
		return nil, err
	}
	resp, err := s.c.Do(req)
	if err != nil {
		return nil, err
	}
	// An error comes as JSON instead of the video.
	if strings.Contains(resp.Header.Get("Content-Type"), "json") {
		defer resp.Body.Close()
		data, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("Download: %s", strings.TrimSpace(string(data)))
	}
	return resp.Body, nil
}

// Close logs out (cmd=Logout): cameras allow few sessions.
func (s *session) Close() {
	if s.token == "" {
		return
	}
	s.cmd(context.Background(), "Logout", map[string]any{}, nil)
	s.token = ""
}
