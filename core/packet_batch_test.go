package main

import (
	"runtime"
	"testing"
)

func TestPacketProfilesTradeLatencyForBatchThroughput(t *testing.T) {
	profiles := []struct {
		name  string
		batch int
	}{
		{"gaming", 32},
		{"latency", 64},
		{"balanced", 128},
		{"throughput", 256},
		{"extreme", 512},
	}
	last := 0
	for _, tc := range profiles {
		workers, batch := packetReadTuning(tc.name)
		if runtime.GOOS == "linux" && batch != tc.batch {
			t.Errorf("%s batch=%d, want %d", tc.name, batch, tc.batch)
		}
		if runtime.GOOS != "linux" && (workers != 1 || batch != 1) {
			t.Errorf("portable fallback is %d workers / %d batch, want 1/1", workers, batch)
		}
		if workers < 1 || workers > runtime.GOMAXPROCS(0) {
			t.Errorf("%s workers=%d outside available CPUs", tc.name, workers)
		}
		if runtime.GOOS == "linux" && batch <= last {
			t.Errorf("%s batch=%d did not grow past %d", tc.name, batch, last)
		}
		last = batch
	}
}

func TestUnknownPacketProfileUsesBalancedTuning(t *testing.T) {
	wantWorkers, wantBatch := packetReadTuning("balanced")
	gotWorkers, gotBatch := packetReadTuning("old-config-with-no-known-profile")
	if gotWorkers != wantWorkers || gotBatch != wantBatch {
		t.Fatalf("old config got %d/%d, balanced is %d/%d",
			gotWorkers, gotBatch, wantWorkers, wantBatch)
	}
}
