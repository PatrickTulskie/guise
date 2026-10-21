//go:build !windows

package main

import (
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// Whether a byte is waiting on stdin within the timeout: the tail of an
// escape sequence arrives at once, a bare Escape key sends nothing more.
func inputReady(d time.Duration) bool {
	fds := []unix.PollFd{{Fd: int32(os.Stdin.Fd()), Events: unix.POLLIN}}
	n, err := unix.Poll(fds, int(d/time.Millisecond))
	return err == nil && n > 0
}
