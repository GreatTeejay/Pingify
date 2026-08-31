//go:build linux && arm64

package carrier

// arm64 uses the generic syscall table, where these two sit at different
// numbers from x86-64. See batch_linux_amd64.go.
const (
	sysRecvmmsg = 243
	sysSendmmsg = 269
)
