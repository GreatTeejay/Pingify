package carrier

import "testing"

// The acknowledgement number in raw TCP's made-up header is the one thing a
// stateful box in the middle checks, so it must only ever look like TCP's:
// forwards, in sequence space, where the numbers wrap.
func TestTheFakeAckOnlyEverMovesForwards(t *testing.T) {
	for _, c := range []struct {
		name      string
		was, next uint32
		want      uint32
	}{
		{"the first segment, low", 0, 1000, 1000},
		// The far end's first sequence number is random. Half of them read as
		// negative against zero; an "only forwards" check that forgot this
		// would never store the first ack for half of all connections.
		{"the first segment, high", 0, 0xF0000000, 0xF0000000},
		{"the next segment", 1000, 2400, 2400},
		{"a reordered segment", 2400, 1000, 2400},
		{"the same segment again", 2400, 2400, 2400},
		{"forwards across the wrap", 0xFFFFFF00, 0x00000100, 0x00000100},
		{"reordered across the wrap", 0x00000100, 0xFFFFFF00, 0x00000100},
		// A restart starts the far end's numbers somewhere else entirely. A
		// step back that large is a new sequence space, not a late packet.
		{"the far end restarted", 0x10000000, 0x90000000, 0x90000000},
		{"a step back of just under a window", 1 << 30, (1 << 30) - (1<<24 - 1), 1 << 30},
		{"a step back of a whole window", 1 << 30, (1 << 30) - (1 << 24), (1 << 30) - (1 << 24)},
	} {
		if got := ackAfter(c.was, c.next); got != c.want {
			t.Errorf("%s: from %#x after %#x acknowledged %#x, expected %#x",
				c.name, c.was, c.next, got, c.want)
		}
	}
}
