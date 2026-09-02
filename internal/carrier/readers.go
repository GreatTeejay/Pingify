package carrier

import "runtime"

// readerCount is how many goroutines read a datagram socket: one per core,
// and never more than four.
//
// One was the number, and on a two core server it was the ceiling: the
// reader alone at 94% of a core, sixteen streams stopping at 330 Mbit/s, and
// the kernel dropping a tenth of what reached the socket because it was not
// being taken off. A single core server gets one reader still - there is
// nothing to be gained by two goroutines sharing one core - and above four
// the lock on the replay window would be the thing they queue for instead.
func readerCount() int {
	n := runtime.NumCPU()
	if n < 1 {
		return 1
	}
	if n > 4 {
		return 4
	}
	return n
}
