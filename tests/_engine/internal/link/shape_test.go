package link

import (
	"strings"
	"testing"
)

// The line measured on the Iran 1 to Germany path, and nothing else: the
// limit, one queue per flow, no priority classes, and the carrier's bytes
// counted with each packet.
func TestCakeIsTheLineThatWasMeasured(t *testing.T) {
	got := strings.Join(cakeArgs("pfy0", 600, 40), " ")
	want := "qdisc replace dev pfy0 root cake bandwidth 600mbit besteffort flows overhead 40"
	if got != want {
		t.Fatalf("tc %s\nwant tc %s", got, want)
	}
}
