package carrier

import "testing"

// What one packet costs on the way in and on the way out. The receiving side
// does open once per packet and nothing else per packet that is not a system
// call, so if the receiver is falling behind at fifty thousand packets a
// second this is where to look first.
func BenchmarkSeal(b *testing.B) {
	f := newFramer("a token typed on both servers", "pingify icmp v1")
	buf := make([]byte, frameLen+1320)
	b.SetBytes(1320)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		f.seal(buf)
	}
}

func BenchmarkOpen(b *testing.B) {
	// Every frame carries a counter the replay window will only accept once,
	// so the window is put aside here and what is measured is the tag, which
	// is the part that costs.
	f := newFramer("a token typed on both servers", "pingify icmp v1")
	g := newFramer("a token typed on both servers", "pingify icmp v1")
	g.reliable = true
	frames := make([][]byte, 4096)
	for i := range frames {
		p := make([]byte, frameLen+1320)
		f.seal(p)
		frames[i] = p
	}
	b.SetBytes(1320)
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, ok := g.open(frames[i%len(frames)]); !ok {
			b.Fatalf("frame %d did not open", i)
		}
	}
}

// The same, from as many goroutines as the receiving side runs, because the
// replay window is behind one lock they all take.
func BenchmarkOpenParallel(b *testing.B) {
	f := newFramer("a token typed on both servers", "pingify icmp v1")
	g := newFramer("a token typed on both servers", "pingify icmp v1")
	frames := make([][]byte, 1<<16)
	for i := range frames {
		p := make([]byte, frameLen+1320)
		f.seal(p)
		frames[i] = p
	}
	b.SetBytes(1320)
	b.ResetTimer()
	var n int
	b.RunParallel(func(pb *testing.PB) {
		i := n
		n += 4096
		for pb.Next() {
			g.open(frames[i%len(frames)])
			i++
		}
	})
}
