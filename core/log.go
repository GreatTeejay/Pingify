package main

import (
	"fmt"
	"os"
	"strings"
	"sync/atomic"
	"time"
)

// Four levels, and the only one that costs anything is debug - which is why
// the check happens before the arguments are formatted rather than inside the
// call that formats them.
const (
	levelDebug = iota
	levelInfo
	levelWarn
	levelError
)

var logLevel int32 = levelInfo

func setLogLevel(name string) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "debug":
		atomic.StoreInt32(&logLevel, levelDebug)
	case "", "info":
		atomic.StoreInt32(&logLevel, levelInfo)
	case "warn", "warning":
		atomic.StoreInt32(&logLevel, levelWarn)
	case "error":
		atomic.StoreInt32(&logLevel, levelError)
	}
}

func logAt(level int32, tag, format string, args ...any) {
	if atomic.LoadInt32(&logLevel) > level {
		return
	}
	fmt.Fprintf(os.Stderr, "%s  %-6s %s\n",
		time.Now().Format("2006-01-02 15:04:05.000"), tag,
		fmt.Sprintf(format, args...))
}

func logDebug(f string, a ...any) { logAt(levelDebug, "DEBUG", f, a...) }
func logInfo(f string, a ...any)  { logAt(levelInfo, "INFO", f, a...) }
func logWarn(f string, a ...any)  { logAt(levelWarn, "WARN", f, a...) }
func logError(f string, a ...any) { logAt(levelError, "ERROR", f, a...) }

// die says why and stops. Used only for what cannot be recovered from at
// startup, never once traffic is flowing.
func die(format string, args ...any) {
	logError(format, args...)
	os.Exit(1)
}
