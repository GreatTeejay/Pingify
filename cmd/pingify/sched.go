package main

import "runtime"

// widenScheduler gives the runtime two processors on a machine that has one.
//
// A tunnel is not short of work, it is short of turns. With one processor Go
// has one P, and a goroutine that becomes runnable waits for the running one
// to reach a point where it can be taken off - which sysmon forces only after
// ten milliseconds. Two of those is twenty, and twenty is what was measured
// on a single-core server in Iran: a packet already read off the device and
// already built sat waiting for a turn to be handed to the wire.
//
//	                   device to wire     round trip
//	one processor       18.63 ms           99.9 ms
//	two                  0.05 ms           81.2 ms
//	four                 0.08 ms           81.3 ms
//
// The wire underneath was 81, so all of the gap was this. Throughput did not
// pay for the fix: sixteen streams carried 391.9 Mbit/s on one processor and
// 391.5 on two.
//
// Two Ps on one core is not two cores. It is permission for a goroutine that
// is ready to run to be picked up while another is still running, which is
// all that was missing - this work waits on sockets, it does not compute.
// Most servers people run this on in Iran have one core.
func widenScheduler() {
	if runtime.GOMAXPROCS(0) < 2 {
		runtime.GOMAXPROCS(2)
	}
}
