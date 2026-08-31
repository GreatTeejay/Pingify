//go:build !(linux && (amd64 || arm64))

package main

import (
	"errors"
	"syscall"
)

// Everywhere the batched calls are not available: a laptop, or a 32-bit
// server. The carrier falls back to one call per packet, which is correct and
// slower, and says so in the log rather than pretending.

const (
	canBatch         = false
	recvBatch        = 1
	sendBatch        = 1
	defaultSendBatch = 1
)

var errNoBatch = errors.New("recvmmsg and sendmmsg are not available here")

type batchReader struct{ n int }

func newBatchReader(size int) *batchReader { return &batchReader{} }

func (r *batchReader) read(rc syscall.RawConn) (int, error) { return 0, errNoBatch }

func (r *batchReader) packet(i int) ([]byte, [4]byte) { return nil, [4]byte{} }

type batchWriter struct{}

func newBatchWriter() *batchWriter { return &batchWriter{} }

func (w *batchWriter) write(rc syscall.RawConn, pkts [][]byte, to [4]byte) (int, error) {
	return 0, errNoBatch
}
