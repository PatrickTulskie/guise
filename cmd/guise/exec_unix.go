//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"
)

// Replaces this process with the command, the way `exec` does in a shell:
// a shell started by `use` and a harness started by `triage` own the
// terminal outright.
func execReplace(name string, args []string, env []string) {
	path, err := exec.LookPath(name)
	if err != nil {
		die(name + ": not found")
	}
	if env == nil {
		env = os.Environ()
	}
	if err := syscall.Exec(path, append([]string{name}, args...), env); err != nil {
		die("could not exec " + name + ": " + err.Error())
	}
}
