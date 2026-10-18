package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/url"
	"strings"

	"github.com/prodbytes/presence/presence_streamer/internal/livesync"
	"github.com/prodbytes/presence/presence_streamer/internal/session"
	"github.com/prodbytes/presence/presence_streamer/internal/sigv4"
)

// liveSync is the streamer's live sync (specs/streamer.md, "Live sync") for
// the profile's identity, or nil when it's off: no IoT endpoint, or a
// setting that's wrong (logged). Off, events reach the profile's devices
// from the bucket, as before; nothing else changes.
func liveSync(o *options, deviceID, identityID string, key []byte, sess *session.Session, logf func(string, ...any)) *livesync.Live {
	if o.iotEndpoint == "" || o.iotEndpoint == "off" {
		logf("live sync: off (no IoT endpoint; PRESENCE_STREAMER_IOT_ENDPOINT sets one)")
		return nil
	}
	stage, err := liveStage(o.stage, o.api)
	if err != nil {
		logf("live sync: off: %v", err)
		return nil
	}
	live, err := livesync.New(livesync.Config{
		Endpoint: o.iotEndpoint, Stage: stage, IdentityID: identityID, DeviceID: deviceID,
		MediaKey: base64.StdEncoding.EncodeToString(key),
		// The session's credentials, renewed 5 minutes before they expire:
		// the connection renews 2 minutes before, with the new ones.
		Credentials: func(ctx context.Context) (sigv4.Credentials, error) {
			aws, err := sess.AWS(ctx)
			return sigv4.Credentials{AccessKeyID: aws.AccessKeyID, SecretKey: aws.SecretKey,
				SessionToken: aws.SessionToken, Expiration: aws.Expiration}, err
		},
		Logf: logf,
	})
	if err != nil {
		logf("live sync: off: %v", err)
		return nil
	}
	logf("live sync: %s, stage %s", o.iotEndpoint, stage)
	return live
}

// liveStage is live sync's stage (the topics' `presence/<stage>/…`, as the
// IoT policy of the auth API's stage allows): stage when set (prod or
// rc); otherwise rc for the release candidate's site (rc.…), prod for any
// other.
func liveStage(stage, api string) (string, error) {
	switch stage {
	case "prod", "rc":
		return stage, nil
	case "":
		if u, err := url.Parse(api); err == nil && strings.HasPrefix(u.Hostname(), "rc.") {
			return "rc", nil
		}
		return "prod", nil
	}
	return "", fmt.Errorf("--stage %q: use prod or rc", stage)
}
