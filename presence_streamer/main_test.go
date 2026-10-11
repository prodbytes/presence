package main

import "testing"

func TestDetectInCloud(t *testing.T) {
	const mb = 1 << 20
	for _, c := range []struct {
		mode  string
		total int64
		cloud bool
	}{
		{"auto", 427 * mb, true},   // Pi Zero W (512 MB)
		{"auto", 922 * mb, true},   // Pi 3 (1 GB)
		{"auto", 1849 * mb, false}, // Pi 4 2 GB, as it reports itself
		{"auto", 7820 * mb, false}, // Pi 5 8 GB
		{"auto", 0, false},         // unknown
		{"local", 427 * mb, false},
		{"cloud", 7820 * mb, true},
	} {
		cloud, why, err := detectInCloud(c.mode, c.total)
		if err != nil || cloud != c.cloud || why == "" {
			t.Errorf("%s with %d MB: cloud %v (%q), %v", c.mode, c.total/mb, cloud, why, err)
		}
	}
	if _, _, err := detectInCloud("gpu", 0); err == nil {
		t.Error("an unknown mode taken")
	}
}

func TestMemTotal(t *testing.T) {
	// Linux only; elsewhere it's unknown (0).
	if total := memTotal(); total < 0 {
		t.Fatalf("memory %d", total)
	}
}
