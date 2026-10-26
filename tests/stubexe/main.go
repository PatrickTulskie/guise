// A native program on Windows starts only real executables, so guise cannot
// run the suite's stand-in scripts by name. Copied to <script>.exe beside a
// script, this runs that script with the same argv, the same streams, and
// its exit status.
package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "stubexe: "+err.Error())
		os.Exit(127)
	}
	// exec from sh honors the script's shebang, which sh <script> would not.
	script := filepath.ToSlash(strings.TrimSuffix(self, ".exe"))
	cmd := exec.Command("sh", append([]string{"-c", `exec "$0" "$@"`, script}, os.Args[1:]...)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err = cmd.Run()
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit):
		os.Exit(exit.ExitCode())
	case err != nil:
		fmt.Fprintln(os.Stderr, "stubexe: "+err.Error())
		os.Exit(127)
	}
}
