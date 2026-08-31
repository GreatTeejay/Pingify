package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

// ==========================================================================
// 2. logging
// ==========================================================================

// Five levels, not seven. panic and fatal say how a program died rather than
// how bad the news is, and both come out of this one as an error followed by
// the process ending - so they would only ever have been two more words for
// the same line. trace is worth its own level: it is the one that prints per
// packet, and mixing that into debug makes debug unusable.
//
//	error   something is broken and stays broken
//	warn    something is wrong but the tunnel carried on
//	info    the things worth knowing on a healthy tunnel
//	debug   why a carrier or a stream did what it did
//	trace   every packet - loud enough to slow a busy tunnel down
const (
	lvlError = 0
	lvlWarn  = 1
	lvlInfo  = 2
	lvlDebug = 3
	lvlTrace = 4
)

var logLevel int32 = lvlInfo

// logNames maps a level to what it is called, both ways round, so the manager
// and the core cannot drift on the spelling.
var logNames = []string{"error", "warn", "info", "debug", "trace"}

func setLogLevel(s string) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "error", "err", "fatal", "panic":
		atomic.StoreInt32(&logLevel, lvlError)
	case "warn", "warning":
		atomic.StoreInt32(&logLevel, lvlWarn)
	case "debug":
		atomic.StoreInt32(&logLevel, lvlDebug)
	case "trace":
		atomic.StoreInt32(&logLevel, lvlTrace)
	default:
		atomic.StoreInt32(&logLevel, lvlInfo)
	}
}

// logSink is where a formatted line goes. Only the tests replace it, so they
// can assert on what an operator would actually have seen - but they replace
// it while the tunnel they are watching is still running, and every goroutine
// in the process reads it. A plain assignment there is a data race, and the
// race detector is right about it, so the swap goes through atomic.Value.
var logSink atomic.Value // holds a func(string)

// stderrSink is where a line goes when nothing has replaced the sink, and
// under systemd that is a pipe to journald. A pipe blocks when it is full,
// and journald fills it whenever it is rate limiting, or the disk is busy, or
// the machine is small. So every log call was a place this process could
// stop - including the ones a carrier's read loop makes for the records it
// dispatches, while the socket it was reading went unread behind it.
//
// That is how a target being down became a tunnel being down. The far end
// refuses every connection there is, sends a record saying so for each one,
// and this end stopped to write a warning about each one. Behind the stalled
// reader the peer's send buffer filled, its keepalives never left the queue,
// and the carrier died of a minute of silence that was ours - then
// reconnected, and the flood started again.
//
// A log line is never worth a carrier. Lines go on a queue and a writer
// drains it; when the queue is full the line is dropped and counted, and the
// count goes out with the next line that fits. Logging that cannot keep up
// now costs log lines, which is the only thing it should ever have cost.
func stderrSink(line string) { stderrLog.write(line) }

var stderrLog = newAsyncWriter(os.Stderr)

// How many lines may be waiting before new ones are dropped. Large enough
// that an ordinary burst - every carrier in a braid reporting at once - is
// never lost, small enough that a wedged journald costs a few hundred
// kilobytes rather than the heap.
const logQueue = 4096

type asyncWriter struct {
	q       chan string
	dropped uint64
}

func newAsyncWriter(w io.Writer) *asyncWriter {
	a := &asyncWriter{q: make(chan string, logQueue)}
	go a.pump(w)
	return a
}

func (a *asyncWriter) write(line string) {
	select {
	case a.q <- line:
	default:
		atomic.AddUint64(&a.dropped, 1)
	}
}

func (a *asyncWriter) pump(w io.Writer) {
	for line := range a.q {
		// Said before the line that made room for it, so the gap is marked
		// where it happened rather than at the end of the burst.
		if d := atomic.SwapUint64(&a.dropped, 0); d > 0 {
			fmt.Fprintln(w, logLine(lvlWarn, fmt.Sprintf(
				"%d log lines dropped - the log could not keep up, and the tunnel did not wait for it", d)))
		}
		fmt.Fprintln(w, line)
	}
}

// flush gives the queue a moment to empty, so that the reason a tunnel
// stopped is not still sitting in a channel when the process ends.
func (a *asyncWriter) flush(d time.Duration) {
	deadline := time.Now().Add(d)
	for len(a.q) > 0 && time.Now().Before(deadline) {
		time.Sleep(2 * time.Millisecond)
	}
}

func logFlush() { stderrLog.flush(2 * time.Second) }

func currentSink() func(string) {
	if f, ok := logSink.Load().(func(string)); ok && f != nil {
		return f
	}
	return stderrSink
}

// setLogSink installs a sink and hands back the one it replaced, so a caller
// can put that one back when it is done listening.
func setLogSink(f func(string)) func(string) {
	prev := currentSink()
	logSink.Store(f)
	return prev
}

// Colour is decided once. journalctl keeps the escapes and renders them; a
// file or a pipe gets none, so a log that is grepped later stays clean.
var logColour = func() bool {
	if os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return false
	}
	fi, err := os.Stderr.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}()

// A log line is three fixed columns and then the message, so a screenful of
// them reads down rather than across:
//
//	2026-08-22 14:31:07.482  INFO   carrier 3 up to 2.26.26.37:9443
//	2026-08-22 14:31:07.913  WARN   no carrier up, dropping connection to :6526
//	2026-08-22 14:32:07.914  ERROR  carrier 3 down: nothing received for 30s
//
// Milliseconds are worth the three characters: carriers come up and die in
// bursts, and whole seconds put four events on the same timestamp with no way
// to tell what happened first.
//
// Red for what is broken, yellow for what is wrong but survivable, cyan for
// what a healthy tunnel does, grey for the two levels that are only ever read
// while chasing something. Journald keeps the escapes and renders them; a file
// or a pipe gets none, so a log that is grepped later stays clean.
var logTags = [5]struct{ plain, coloured string }{
	{"ERROR", "\033[1;31mERROR\033[0m"},
	{"WARN ", "\033[1;33mWARN \033[0m"},
	{"INFO ", "\033[36mINFO \033[0m"},
	{"DEBUG", "\033[90mDEBUG\033[0m"},
	{"TRACE", "\033[90mTRACE\033[0m"},
}

const logStamp = "2006-01-02 15:04:05.000"

func logLine(lvl int32, msg string) string {
	tag := logTags[lvl].plain
	stamp := time.Now().Format(logStamp)
	if logColour {
		tag = logTags[lvl].coloured
		stamp = "\033[90m" + stamp + "\033[0m"
	}
	return fmt.Sprintf("%s  %s  %s", stamp, tag, msg)
}

func logAt(lvl int32, format string, args ...interface{}) {
	if atomic.LoadInt32(&logLevel) < lvl {
		return
	}
	currentSink()(logLine(lvl, fmt.Sprintf(format, args...)))
}

func logError(f string, a ...interface{}) { logAt(lvlError, f, a...) }
func logWarn(f string, a ...interface{})  { logAt(lvlWarn, f, a...) }
func logInfo(f string, a ...interface{})  { logAt(lvlInfo, f, a...) }
func logDebug(f string, a ...interface{}) { logAt(lvlDebug, f, a...) }
func logTrace(f string, a ...interface{}) { logAt(lvlTrace, f, a...) }
