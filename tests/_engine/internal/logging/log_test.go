package logging

import (
	"os"
	"strings"
	"testing"
)

// capture runs f with stderr redirected and returns what was written.
func capture(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	os.Stderr = w
	f()
	os.Stderr = old
	w.Close()
	var sb strings.Builder
	buf := make([]byte, 4096)
	for {
		n, err := r.Read(buf)
		sb.Write(buf[:n])
		if err != nil {
			break
		}
	}
	r.Close()
	return sb.String()
}

// The level filter once compared a parameter with itself and let every debug
// line through at every level. It must drop what is below the level and keep
// what is at or above it.
func TestLevelFilters(t *testing.T) {
	defer SetLevel("info")
	cases := []struct {
		level string
		want  []string
		drop  []string
	}{
		{"debug", []string{"DEBUG", "INFO", "WARN", "ERROR"}, nil},
		{"info", []string{"INFO", "WARN", "ERROR"}, []string{"DEBUG"}},
		{"warn", []string{"WARN", "ERROR"}, []string{"DEBUG", "INFO"}},
		{"error", []string{"ERROR"}, []string{"DEBUG", "INFO", "WARN"}},
		{"", []string{"INFO"}, []string{"DEBUG"}},
		{"nonsense", []string{"INFO"}, []string{"DEBUG"}},
	}
	for _, c := range cases {
		SetLevel("info")
		SetLevel(c.level)
		out := capture(t, func() {
			Debug("d %d", 1)
			Info("i %d", 2)
			Warn("w %d", 3)
			Error("e %d", 4)
		})
		for _, tag := range c.want {
			if !strings.Contains(out, tag) {
				t.Errorf("level %q: %s line missing from %q", c.level, tag, out)
			}
		}
		for _, tag := range c.drop {
			if strings.Contains(out, tag) {
				t.Errorf("level %q: %s line printed: %q", c.level, tag, out)
			}
		}
	}
}

func TestLineShape(t *testing.T) {
	SetLevel("info")
	out := capture(t, func() { Warn("something %s", "odd") })
	// 2006-01-02 15:04:05.000  WARN   something odd
	if !strings.HasSuffix(strings.TrimSpace(out), "WARN   something odd") {
		t.Fatalf("unexpected line: %q", out)
	}
	if len(out) < len("2006-01-02 15:04:05.000  ") {
		t.Fatalf("no timestamp: %q", out)
	}
}
