package config

import (
	"strings"
	"testing"
)

// linkDoc is a private link over ICMP, one side of it, with extra lines for
// its [tun] table.
func linkDoc(side, extra string) string {
	return `
[tunnel]
side = "` + side + `"
mode = "tun"
[transport]
type = "icmp"
iran = "198.51.100.7"
kharej = "203.0.113.9"
dials = "iran"
[security]
token = "a token typed on both servers"
[tun]
name = "pfy0"
iran = "10.99.1.1/24"
kharej = "10.99.1.2/24"
` + extra + `
`
}

// One file on both servers, and each takes its own number from it: the
// abroad server's limit is the users' download, Iran's their upload.
func TestEachServerTakesItsOwnLimit(t *testing.T) {
	both := "shape_iran_mbit = 300\nshape_kharej_mbit = 600"
	for side, want := range map[string]int{"iran": 300, "kharej": 600} {
		c, err := checkedDoc(linkDoc(side, both))
		if err != nil {
			t.Fatalf("%s: %v", side, err)
		}
		if got := c.ShapeMbit(); got != want {
			t.Fatalf("%s limits itself to %d Mbit/s, the file says %d", side, got, want)
		}
	}
}

// Nothing written is no limit, which is what every link had before.
func TestNoLimitUnlessOneIsWritten(t *testing.T) {
	for _, side := range []string{"iran", "kharej"} {
		c, err := checkedDoc(linkDoc(side, ""))
		if err != nil {
			t.Fatalf("%s: %v", side, err)
		}
		if c.ShapeMbit() != 0 {
			t.Fatalf("%s is limited to %d Mbit/s with nothing in the file", side, c.ShapeMbit())
		}
	}
}

func TestALimitIsARate(t *testing.T) {
	for _, line := range []string{"shape_kharej_mbit = -1", "shape_iran_mbit = 100001"} {
		_, err := checkedDoc(linkDoc("kharej", line))
		if err == nil || !strings.Contains(err.Error(), "Mbit/s") {
			t.Fatalf("%q: want it refused as not a rate, got %v", line, err)
		}
	}
}

// Over GRE-FOU the device is the kernel's, made by the manager, and nothing
// in the core would put cake on it.
func TestALimitOnAKernelDeviceIsSaidToDoNothing(t *testing.T) {
	c := &Config{}
	body := strings.Replace(linkDoc("kharej", "shape_kharej_mbit = 600"), `type = "icmp"`, `type = "grefou"`, 1)
	if err := parseTOML(body, c); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.Join(c.Inert(), " "), "tun.shape_kharej_mbit") {
		t.Fatalf("the limit on a GRE-FOU link was not reported as doing nothing: %v", c.Inert())
	}
}
