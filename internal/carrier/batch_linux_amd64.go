//go:build linux && amd64

package carrier

// The two calls this core makes by number, because Go's syscall package
// exports SYS_RECVMMSG on some architectures and SYS_SENDMMSG on none of them.
// Both have been fixed kernel ABI since 2.6.33 and 3.0.
const (
	sysRecvmmsg = 299
	sysSendmmsg = 307
)
