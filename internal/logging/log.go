package logging

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

var level int32 = levelInfo

func SetLevel(name string) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "debug":
		atomic.StoreInt32(&level, levelDebug)
	case "", "info":
		atomic.StoreInt32(&level, levelInfo)
	case "warn", "warning":
		atomic.StoreInt32(&level, levelWarn)
	case "error":
		atomic.StoreInt32(&level, levelError)
	}
}

func at(level int32, tag, format string, args ...any) {
	if atomic.LoadInt32(&level) > level {
		return
	}
	fmt.Fprintf(os.Stderr, "%s  %-6s %s\n",
		time.Now().Format("2006-01-02 15:04:05.000"), tag,
		fmt.Sprintf(format, args...))
}

func Debug(f string, a ...any) { at(levelDebug, "DEBUG", f, a...) }
func Info(f string, a ...any)  { at(levelInfo, "INFO", f, a...) }
func Warn(f string, a ...any)  { at(levelWarn, "WARN", f, a...) }
func Error(f string, a ...any) { at(levelError, "ERROR", f, a...) }

// Die says why and stops. Used only for what cannot be recovered from at
// startup, never once traffic is flowing.
func Die(format string, args ...any) {
	Error(format, args...)
	os.Exit(1)
}
