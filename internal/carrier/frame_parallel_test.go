package carrier

import (
	"sync"
	"testing"
)

// A datagram carrier may read its socket from several goroutines now, and
// every one of them opens frames through the same window. Each sealed frame
// has to be accepted exactly once, whichever goroutine gets it.
func TestFramesAreOpenedOnceFromManyGoroutines(t *testing.T) {
	f := newFramer("a token", "test")
	const n = 4000
	frames := make([][]byte, n)
	for i := range frames {
		frames[i] = make([]byte, frameLen+24)
		f.seal(frames[i])
	}
	var wg sync.WaitGroup
	var mu sync.Mutex
	opened := 0
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := g; i < n; i += 8 {
				if _, ok := f.open(frames[i]); ok {
					mu.Lock()
					opened++
					mu.Unlock()
				}
			}
		}(g)
	}
	wg.Wait()
	if opened != n {
		t.Fatalf("%d of %d frames were accepted; a window with no lock loses count", opened, n)
	}
	if _, ok := f.open(frames[7]); ok {
		t.Fatal("a frame opened twice")
	}
}
