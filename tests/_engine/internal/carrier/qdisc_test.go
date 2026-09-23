package carrier

import "testing"

// What is on the interface decides whether it may be replaced. Getting this
// wrong is not a performance bug: `tc qdisc replace ... root fq` over an HTB
// tree takes every class and filter under it away, without an error, on a
// core restart months after somebody built it.
func TestOnlyAQueueNobodyChoseIsReplaced(t *testing.T) {
	for _, c := range []struct {
		line    string
		replace bool
	}{
		{"qdisc fq_codel 0: root refcnt 2 limit 10240p flows 1024", true},
		{"qdisc pfifo_fast 0: root refcnt 2 bands 3", true},
		{"qdisc noqueue 0: root refcnt 2", true},
		{"qdisc fq 8001: root refcnt 2 limit 10000p flow_limit 9000p", true},
		// Somebody's, every one of them.
		{"qdisc htb 1: root refcnt 2 r2q 10 default 0x20", false},
		{"qdisc cake 8001: root refcnt 2 bandwidth 100Mbit", false},
		{"qdisc tbf 8001: root refcnt 2 rate 10Mbit burst 15kb", false},
		{"qdisc hfsc 1: root refcnt 2 default 1", false},
		// A default, but replacing it collapses one queue per hardware queue
		// onto one lock, so it is left alone too.
		{"qdisc mq 0: root", false},
		{"", false},
	} {
		if got := defaultQdisc(c.line); got != c.replace {
			t.Errorf("%q: may replace = %v, expected %v", qdiscKind(c.line), got, c.replace)
		}
	}
}

func TestTheQueuesNameIsReadOutOfTheLine(t *testing.T) {
	if got := qdiscKind("qdisc fq 8001: root refcnt 2 limit 10000p"); got != "fq" {
		t.Errorf("read %q, expected fq", got)
	}
	if got := qdiscKind("nonsense"); got == "fq" {
		t.Errorf("a line that is not a qdisc read as one: %q", got)
	}
}
