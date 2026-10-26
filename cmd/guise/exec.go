package main

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
)

// The environment with key set to value and nothing else changed. Appending
// to os.Environ() would leave the inherited entry in place, and a Go program
// reads the first one it finds.
func envWith(key, value string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, key+"=") {
			env = append(env, kv)
		}
	}
	return append(env, key+"="+value)
}

func have(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// stdout with trailing newlines dropped, the way $(...) hands it back.
// A file saved on Windows ends its lines in CRLF, and a stray \r left on a
// token or on a PEM's END line breaks it.
func chomp(s string) string { return strings.TrimRight(s, "\r\n") }

// Runs a command with nothing attached to stdin and its stderr discarded.
func output(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Stdin = nil
	out, err := cmd.Output()
	return chomp(string(out)), err
}

// The same, with stderr passed through: for commands whose complaint is the
// useful part of a failure.
func outputLoud(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	return chomp(string(out)), err
}

func outputWithStdin(stdin string, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Stdin = strings.NewReader(stdin)
	out, err := cmd.Output()
	return chomp(string(out)), err
}

// True when the command exits 0; nothing it prints goes anywhere.
func succeeds(name string, args ...string) bool {
	cmd := exec.Command(name, args...)
	cmd.Stdin = nil
	return cmd.Run() == nil
}

// Runs a command with the terminal: for git clone, ssh-keygen and the like.
func runLoud(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func exitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	if err == nil {
		return 0
	}
	return 1
}

// `git -C dir args...`, trimmed; ok is whether git exited 0.
func git(dir string, args ...string) (string, bool) {
	all := args
	if dir != "" {
		all = append([]string{"-C", dir}, args...)
	}
	out, err := output("git", all...)
	return out, err == nil
}

func stderrOf(err error) string {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return chomp(string(ee.Stderr))
	}
	return ""
}

func drain(r io.Reader) { _, _ = io.Copy(io.Discard, r) }
