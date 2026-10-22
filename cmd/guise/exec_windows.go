//go:build windows

package main

import (
	"os"
	"os/exec"
	"os/signal"
)

// Windows has no exec(2): run the command as a child and leave with its
// status.
func execReplace(name string, args []string, env []string) {
	cmd := exec.Command(name, args...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if env != nil {
		cmd.Env = env
	}
	// The console delivers Ctrl+C to the child and to us alike; only the
	// child should act on it, or the prompt comes back under a live harness.
	signal.Ignore(os.Interrupt)
	err := cmd.Run()
	if err != nil && exitCode(err) == 1 && cmd.ProcessState == nil {
		die("could not run " + name + ": " + err.Error())
	}
	os.Exit(exitCode(err))
}
