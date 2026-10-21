//go:build windows

package main

import (
	"os"
	"time"

	"golang.org/x/sys/windows"
)

func inputReady(d time.Duration) bool {
	r, err := windows.WaitForSingleObject(windows.Handle(os.Stdin.Fd()), uint32(d/time.Millisecond))
	return err == nil && r == windows.WAIT_OBJECT_0
}
