package main

import (
	"os"
	"path/filepath"
	"runtime"
)

// Everything below is fixed for the life of one invocation, the way the
// bash script's globals were.
var (
	home           string
	configDir      string
	configFile     string
	ownedGitconfig string
	renderDir      string
	hooksDir       string
	dispatchDir    string
	keysDir        string
	shellHookPath  string
	binDir         string
	cacheDir       string
	defaultBasedir string
	githubAPI      string
	// The binary this is, symlinks resolved: what `update` installs and what
	// the shims it writes call back into.
	exePath string
)

const (
	defaultVault = "Private"
	markStart    = "# >>> guise >>>"
	markEnd      = "# <<< guise <<<"
	// Setup writes a secret through a JSON template on op's stdin, never an
	// assignment in argv, and fetches the item revealed first so its other
	// concealed fields survive the round trip. `--reveal` arrived in 2.30.
	opMinVersion = "2.30"
	upstream     = "PatrickTulskie/guise"
)

var exeSuffix = map[bool]string{true: ".exe", false: ""}[runtime.GOOS == "windows"]

var exeName = "guise" + exeSuffix

var helpers = []string{"guise-token", "guise-credential", "guise-gh"}

// Every hook git looks up by name, from githooks(5). fsmonitor-watchman is
// left out: core.fsmonitor names it by path, so a hooks directory never
// serves it.
var gitHooks = []string{
	"applypatch-msg", "pre-applypatch", "post-applypatch", "pre-commit",
	"pre-merge-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-rebase",
	"post-checkout", "post-merge", "pre-push", "pre-receive", "update", "proc-receive",
	"post-receive", "post-update", "reference-transaction", "push-to-checkout", "pre-auto-gc",
	"post-rewrite", "sendemail-validate", "p4-changelist", "p4-prepare-changelist",
	"p4-post-changelist", "p4-pre-submit", "post-index-change",
}

func initEnv() {
	// HOME first: under Git Bash it names the shell's home, which is not
	// always the profile directory the OS would answer with.
	home = os.Getenv("HOME")
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	configDir = filepath.Join(home, ".config", "guise")
	// The helpers have always read GUISE_CONFIG, and `guise which` answers
	// guise-gh's "whose directory is this?" -- so everything resolves against
	// the same config, or the two disagree about which identity is current.
	configFile = os.Getenv("GUISE_CONFIG")
	if configFile == "" {
		configFile = filepath.Join(configDir, "config")
	}
	ownedGitconfig = filepath.Join(configDir, "gitconfig")
	renderDir = filepath.Join(configDir, "git")
	hooksDir = filepath.Join(renderDir, "agent-hooks")
	dispatchDir = filepath.Join(renderDir, "hooks")
	keysDir = filepath.Join(configDir, "keys")
	shellHookPath = filepath.Join(configDir, "hook.sh")
	binDir = filepath.Join(home, ".local", "bin")
	cache := os.Getenv("XDG_CACHE_HOME")
	if cache == "" {
		cache = filepath.Join(home, ".cache")
	}
	cacheDir = filepath.Join(cache, "guise")
	defaultBasedir = filepath.Join(home, "agentic-code")
	githubAPI = os.Getenv("GUISE_GITHUB_API")
	if githubAPI == "" {
		githubAPI = "https://api.github.com"
	}
	exePath, _ = os.Executable()
	if real, err := filepath.EvalSymlinks(exePath); err == nil {
		exePath = real
	}
}
