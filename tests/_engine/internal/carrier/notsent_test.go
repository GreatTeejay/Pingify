package carrier

import (
	"testing"

	"pingify/internal/config"
)

// In forward mode this is the only queue a profile can shorten. The socket
// buffers are deliberately left to the kernel's auto-tuning (see prep in
// stream.go) and fq's flow limit counts one TCP flow, which eight carrier
// connections never come near - so if this mapping stops working, the profile
// stops meaning anything at all for tcp, ws, wss, utls and fallback.
func TestTheProfileMovesWhatAStreamMayPark(t *testing.T) {
	for _, c := range []struct {
		profile string
		want    int
	}{
		// What waits here waits in the kernel's order, behind the downloads,
		// out of reach of the forwarder's fair scheduler - so as little as
		// the floor below allows (docs/measured.md section 45).
		{config.ProfileGaming, 32 << 10},
		{config.ProfileBalanced, 32 << 10},
		// Not 512: measured to stall a small stream past five seconds for
		// no throughput (docs/measured.md section 39).
		{config.ProfileThroughput, 64 << 10},
		{config.ProfileStable, 32 << 10}, // a lossy path: the small stream first
		{config.ProfileMax, 64 << 10},
		{"", 32 << 10}, // an unnamed profile is balanced
	} {
		cfg := &config.Config{}
		cfg.Tuning.Profile = c.profile
		if got := notsentLowat(cfg); got != c.want {
			t.Errorf("profile %q parks %d bytes, expected %d", c.profile, got, c.want)
		}
	}
}

// Every profile has to leave more than one packet's worth, or a writer is
// woken for each one and the connection spends its time in system calls.
func TestNoProfileParksLessThanAWindowWorthOfPackets(t *testing.T) {
	for _, p := range []string{config.ProfileGaming, config.ProfileBalanced, config.ProfileThroughput, config.ProfileStable, config.ProfileMax} {
		cfg := &config.Config{}
		cfg.Tuning.Profile = p
		if got := notsentLowat(cfg); got < 32<<10 {
			t.Errorf("profile %q parks only %d bytes", p, got)
		}
	}
}
