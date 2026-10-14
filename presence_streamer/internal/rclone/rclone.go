// Package rclone puts, moves and deletes objects in the profile's folder
// of the user-data bucket with rclone, using the profile's temporary AWS
// credentials. Credentials go through the environment, never the command
// line (which other users see in ps).
package rclone

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/prodbytes/presence/presence_streamer/internal/presence"
)

// Folder is the profile's folder in the bucket.
type Folder struct {
	// Rclone is the rclone binary.
	Rclone string
	// Config is rclone's config file: an empty one, so the user's own
	// remotes and settings never apply.
	Config string
	Bucket string
	// Identity is the profile's identity ID (`us-east-1:<uuid>`), its
	// folder.
	Identity string
	Region   string
	// Endpoint is another S3 endpoint (tests); empty is AWS.
	Endpoint string
	// BandwidthLimit is rclone's --bwlimit (e.g. "1M"); empty is none.
	BandwidthLimit string
	// Credentials gives current AWS credentials for the folder.
	Credentials func(context.Context) (presence.AWS, error)
}

// remote is key's path as an rclone on-the-fly S3 remote.
func (f *Folder) remote(key string) string {
	return ":s3:" + f.Bucket + "/" + f.Identity + "/" + key
}

func (f *Folder) run(ctx context.Context, args ...string) error {
	creds, err := f.Credentials(ctx)
	if err != nil {
		return err
	}
	all := []string{
		"--config", f.Config,
		"--s3-no-check-bucket", // the role may not create or list buckets
		"--s3-no-head",         // nor needs a HEAD after each upload
		"--no-traverse",
		"--retries", "3",
		"--low-level-retries", "10",
		"--stats", "0",
		"-q",
	}
	if f.BandwidthLimit != "" {
		all = append(all, "--bwlimit", f.BandwidthLimit)
	}
	cmd := exec.CommandContext(ctx, f.Rclone, append(args, all...)...)
	provider := "AWS"
	if f.Endpoint != "" {
		provider = "Other"
	}
	cmd.Env = append(os.Environ(),
		"RCLONE_S3_PROVIDER="+provider,
		"RCLONE_S3_REGION="+f.Region,
		"RCLONE_S3_ENDPOINT="+f.Endpoint,
		"RCLONE_S3_ENV_AUTH=false",
		"RCLONE_S3_ACCESS_KEY_ID="+creds.AccessKeyID,
		"RCLONE_S3_SECRET_ACCESS_KEY="+creds.SecretKey,
		"RCLONE_S3_SESSION_TOKEN="+creds.SessionToken,
		// As the app: objects in Intelligent-Tiering, single PUTs (so an
		// object's ETag is its MD5, which the app's sync relies on).
		"RCLONE_S3_STORAGE_CLASS=INTELLIGENT_TIERING",
		"RCLONE_S3_UPLOAD_CUTOFF=5G",
	)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("rclone %s: %w: %s", args[0], err, strings.TrimSpace(out.String()))
	}
	return nil
}

// Put uploads the file path to key, with contentType.
func (f *Folder) Put(ctx context.Context, path, key, contentType string) error {
	return f.run(ctx, "copyto", path, f.remote(key), "--header-upload", "Content-Type: "+contentType)
}

// Move moves from to to in the bucket (a server-side copy, then a delete).
func (f *Folder) Move(ctx context.Context, from, to string) error {
	return f.run(ctx, "moveto", f.remote(from), f.remote(to))
}

// Delete deletes key.
func (f *Folder) Delete(ctx context.Context, key string) error {
	return f.run(ctx, "deletefile", f.remote(key))
}

// Get downloads key to the file path; os.ErrNotExist when there's no such
// object.
func (f *Folder) Get(ctx context.Context, key, path string) error {
	err := f.run(ctx, "copyto", f.remote(key), path)
	if err != nil && strings.Contains(strings.ToLower(err.Error()), "not found") {
		return fmt.Errorf("%s: %w", key, os.ErrNotExist)
	}
	return err
}
