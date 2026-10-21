//go:build windows

package main

import (
	"os"
	"os/exec"
)

// Windows has no exec(2): run the command as a child and leave with its
// status.
func execReplace(name string, args []string, env []string) {
	cmd := exec.Command(name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if env != nil {
		cmd.Env = env
	}
	err := cmd.Run()
	if err != nil && exitCode(err) == 1 && cmd.ProcessState == nil {
		die("could not run " + name + ": " + err.Error())
	}
	os.Exit(exitCode(err))
}
