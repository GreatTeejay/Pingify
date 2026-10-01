package status

import (
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"pingify/internal/config"
)

// A carrier with backups, as far as the report is concerned, that remembers
// what the menu asked of it.
type fakeFailover struct {
	asked []string
	no    bool // the side that waits, which decides nothing
}

func (f *fakeFailover) Counters() (rx, tx, bad, replay, errs uint64) { return }
func (f *fakeFailover) Lost() (missing, late, gaps uint64)           { return }
func (f *fakeFailover) Up() bool                                     { return true }
func (f *fakeFailover) Members() []string                            { return []string{"fallback", "wss"} }
func (f *fakeFailover) Active() string                               { return "fallback" }
func (f *fakeFailover) Lines() []string {
	return []string{"0 fallback 443 - use - 0 ok 71", "1 wss 2083 edge.example.com - - - - -"}
}
func (f *fakeFailover) Control(op string, to int, stay bool) (string, error) {
	if f.no {
		return "", errors.New("the other server dials")
	}
	f.asked = append(f.asked, op)
	return "done: " + op, nil
}

type noLink struct{}

func (noLink) Dropped() uint64                    { return 0 }
func (noLink) Packets() (toWire, toDevice uint64) { return 0, 0 }

func serve(t *testing.T, f *fakeFailover, control bool) *httptest.Server {
	t.Helper()
	s := New(&config.Config{Mode: "forward"}, "test", f, noLink{})
	ts := httptest.NewServer(s.handler(control))
	t.Cleanup(ts.Close)
	return ts
}

func TestTheMenuReadsTheMembersAndMovesTheTunnel(t *testing.T) {
	f := &fakeFailover{}
	ts := serve(t, f, true)

	r, err := http.Get(ts.URL + "/failover")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r.Body)
	r.Body.Close()
	if r.StatusCode != 200 || !strings.Contains(string(b), "1 wss 2083 edge.example.com") {
		t.Fatalf("GET /failover: %d %q", r.StatusCode, b)
	}

	// Reading is a GET; moving the tunnel is not.
	r, _ = http.Get(ts.URL + "/failover/use?to=1")
	r.Body.Close()
	if r.StatusCode != http.StatusMethodNotAllowed || len(f.asked) != 0 {
		t.Fatalf("a GET moved the tunnel: %d, asked %v", r.StatusCode, f.asked)
	}
	r, _ = http.PostForm(ts.URL+"/failover/use", url.Values{"to": {"1"}, "stay": {"1"}})
	r.Body.Close()
	if r.StatusCode != 200 || len(f.asked) != 1 || f.asked[0] != "use" {
		t.Fatalf("POST use: %d, asked %v", r.StatusCode, f.asked)
	}
	r, _ = http.PostForm(ts.URL+"/failover/use", url.Values{"to": {"one"}})
	r.Body.Close()
	if r.StatusCode != http.StatusBadRequest {
		t.Errorf("a member that is not a number: %d", r.StatusCode)
	}
}

// The side that waits says why it cannot, rather than pretending it did.
func TestTheWaitingSideSaysWhyItCannotMove(t *testing.T) {
	ts := serve(t, &fakeFailover{no: true}, true)
	r, _ := http.PostForm(ts.URL+"/failover/check", nil)
	b, _ := io.ReadAll(r.Body)
	r.Body.Close()
	if r.StatusCode != http.StatusConflict || !strings.Contains(string(b), "the other server dials") {
		t.Fatalf("%d %q", r.StatusCode, b)
	}
}

// Only the loopback address takes requests: the link address serves the same
// report to the server at the other end, which must not move this tunnel.
func TestTheLinkAddressCannotMoveTheTunnel(t *testing.T) {
	f := &fakeFailover{}
	ts := serve(t, f, false)
	r, _ := http.PostForm(ts.URL+"/failover/use", url.Values{"to": {"1"}})
	r.Body.Close()
	if len(f.asked) != 0 {
		t.Fatalf("the link address moved the tunnel (%d)", r.StatusCode)
	}
}
