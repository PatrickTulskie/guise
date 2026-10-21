package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

var harnesses = []string{"claude", "codex", "cursor-agent", "opencode", "pi"}

func harnessLabel(h string) string {
	switch h {
	case "claude":
		return "Claude Code"
	case "codex":
		return "Codex"
	case "cursor-agent":
		return "Cursor Agent"
	case "opencode":
		return "OpenCode"
	case "pi":
		return "Pi"
	}
	return h
}

// The checkout this copy was built from, when it is still here, so the agent
// reads the source and docs that match the binary. A development build
// remembers where its source was; a release build is made with -trimpath and
// does not, and then a build sitting in a checkout's bin/ still names it.
func sourceRoot() (string, bool) {
	candidates := []string{filepath.Dir(filepath.Dir(exePath))}
	if _, file, _, ok := runtime.Caller(0); ok && filepath.IsAbs(file) {
		candidates = append([]string{filepath.Dir(filepath.Dir(filepath.Dir(file)))}, candidates...)
	}
	for _, root := range candidates {
		if isFile(filepath.Join(root, "docs", "troubleshooting.md")) && isDir(filepath.Join(root, "cmd", "guise")) {
			return root, true
		}
	}
	return "", false
}

func docRef(rel string) string {
	if root, ok := sourceRoot(); ok {
		return filepath.Join(root, rel)
	}
	return "https://github.com/" + upstream + "/blob/main/" + rel
}

func sourceRef() string {
	if root, ok := sourceRoot(); ok {
		return filepath.Join(root, "cmd", "guise")
	}
	return "https://github.com/" + upstream + "/tree/v" + version + "/cmd/guise"
}

func unameSR() string {
	if out, err := output("uname", "-sr"); err == nil && out != "" {
		return out
	}
	return runtime.GOOS + " " + runtime.GOARCH
}

func triagePrompt() string {
	installed := "not installed"
	if p := filepath.Join(binDir, exeName); isFile(p) {
		if v, err := output(p, "--version"); err == nil {
			installed = p + ", version " + strings.TrimPrefix(v, "guise ")
		} else {
			installed = p + ", answering nothing for --version"
		}
	}
	config := "missing -- setup may never have finished"
	if configExists() {
		config = "present"
	}
	here := "a directory no identity owns"
	if configExists() {
		if name, ok := identityFromCwd(); ok {
			here = "identity '" + name + "''s directory"
		}
	}

	return `You're helping someone figure out what's wrong with their guise setup. guise
gives coding agents a GitHub identity of their own, so commits and pushes made
under an identity's directory come from a separate GitHub account or App bot
instead of the human you're talking to.

What we already know:
- guise ` + version + `, run from ` + exePath + `
- installed copy: ` + installed + `
- config: ` + configFile + ` (` + config + `)
- triage was started from ` + cwd() + `, ` + here + `
- ` + unameSR() + `

1. First ask them, in their own words, what they ran, what they expected, and
   what happened instead -- and to paste the exact error or a screenshot. Wait
   for the answer before investigating.
2. Run ` + "`guise doctor`" + `. It covers a lot but not everything, so a green doctor
   doesn't clear guise.
3. Read the source. One Go package is the whole tool, and the helpers, hooks
   and git config it installs are shims and templates inside it:
     ` + sourceRef() + `
   The troubleshooting guide is keyed to real failure modes:
     ` + docRef("docs/troubleshooting.md") + `
4. Look at their machine: ~/.gitconfig, ~/.config/guise/, ` + "`guise list`" + `, and
   ` + "`git config --show-origin --list`" + ` and ` + "`git remote -v`" + ` in the repo that
   misbehaved.
5. Tell them the root cause, the evidence, and the fix, keeping what you
   verified apart from what you suspect.

Ground rules:
- Ask before changing anything on their machine. Never run ` + "`guise uninstall`" + `,
  ` + "`rm`" + ` or ` + "`rename`" + ` yourself, and fix rendered files with ` + "`guise update`" + `,
  not by hand.
- Never print a secret: no ` + "`guise token`" + `, no unfiltered
  ` + "`git credential fill`" + `, nothing read from ~/.config/guise/keys/,
  ~/.cache/guise/ or 1Password. If they paste a token or key, tell them to
  revoke it.

If the bug is in guise itself rather than their setup, offer at the end to open
a pull request with the fix. It has to come from an identity with its own
GitHub account (kind "user" in ` + "`guise list`" + `); an App bot can't fork or push
to ` + upstream + `. With one that works:
  ` + "`guise clone " + upstream + " --name <identity>`" + `, then
  ` + "`guise-gh repo fork --remote`" + ` inside the clone, and follow its AGENTS.md.
Use ` + "`guise-gh`" + `, never plain ` + "`gh`" + `, which is logged in as the human. Without
one, give them the diff and suggest an account identity for next time.`
}

func launchHarness(h, prompt string) {
	if h == "opencode" {
		execReplace("opencode", []string{"--prompt", prompt}, nil)
	}
	execReplace(h, []string{prompt}, nil)
}

func cmdTriage(args []string) {
	harness, print := "", false
	for len(args) > 0 {
		switch args[0] {
		case "--harness":
			if len(args) < 2 {
				die("triage: --harness needs a value")
			}
			harness = args[1]
			args = args[2:]
		case "--print":
			print = true
			args = args[1:]
		default:
			die("triage: unknown flag '" + args[0] + "'")
		}
	}
	if harness != "" {
		known := false
		for _, h := range harnesses {
			if h == harness {
				known = true
			}
		}
		if !known {
			die("triage: unknown harness '" + harness + "' (supported: " + strings.Join(harnesses, " ") + ")")
		}
		if !have(harness) {
			die("triage: " + harness + " is not on your PATH")
		}
	}

	prompt := triagePrompt()
	if print {
		say(prompt)
		return
	}
	if harness != "" {
		launchHarness(harness, prompt)
	}

	// Without a terminal there is nothing to hold a session, and the prompt
	// is what the caller -- a pipe, or an agent already in a session -- can
	// use.
	if !isTerminal(os.Stdin) || !isTerminal(os.Stdout) {
		say(prompt)
		return
	}

	var found []string
	for _, h := range harnesses {
		if have(h) {
			found = append(found, h)
		}
	}
	if len(found) == 0 {
		warn("found none of " + strings.Join(harnesses, " ") + " on your PATH -- paste this into the one you use:")
		say("")
		say(prompt)
		return
	}

	wzInit()
	wz.cmd = "triage"
	wzLine("")
	wzLine(wz.dim + "┌" + wz.off + "  " + wz.inv + " guise " + wz.off + "  " + wz.bold + "Let's figure out what's going on" + wz.off)
	wzBar()
	wzBar("An agent will ask what went wrong, then read guise's source, run")
	wzBar("guise doctor, and look around your machine. It asks before it changes")
	wzBar("anything. Paste it error text or screenshots as you go -- never a")
	wzBar("token or a key.")
	wzBar()

	var opts []wzOption
	for _, h := range found {
		opts = append(opts, wzOption{h, harnessLabel(h), ""})
	}
	opts = append(opts, wzOption{"print", "Just print the prompt", "to paste into a harness of your own"})
	harness = wzSelect("Which harness should run it?", opts)
	if harness == "print" {
		wzLine(wz.dim + "└" + wz.off)
		say(prompt)
		return
	}
	wzLine(wz.dim + "└" + wz.off + "  Starting " + harnessLabel(harness) + "...")
	launchHarness(harness, prompt)
}
