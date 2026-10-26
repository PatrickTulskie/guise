package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// ---------------------------------------------------------------------------
// Rendering + ~/.gitconfig wiring
// ---------------------------------------------------------------------------

func installBinaries() {
	mkdirAll(binDir, 0o755)
	target := filepath.Join(binDir, exeName)
	if !sameFile(exePath, target) {
		copyExecutable(exePath, target)
	}
	for _, h := range helpers {
		writeFile(filepath.Join(binDir, h), helperShim(h), 0o755)
	}
}

// Written beside the target and renamed over it, so a copy that is being
// run from somewhere is replaced rather than written into.
func copyExecutable(src, dst string) {
	data, err := os.ReadFile(src)
	if err != nil {
		die("could not read " + src + ": " + err.Error())
	}
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, data, 0o755); err != nil {
		die("could not write " + tmp + ": " + err.Error())
	}
	chmod(tmp, 0o755)
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		die("could not install " + dst + ": " + err.Error())
	}
}

func binDirOnPath() bool {
	for _, d := range filepath.SplitList(os.Getenv("PATH")) {
		if d == binDir || (d != "" && filepath.Clean(d) == filepath.Clean(binDir)) {
			return true
		}
	}
	return false
}

func pathLine() string {
	return `export PATH="$HOME` + filepath.ToSlash(strings.TrimPrefix(binDir, home)) + `:$PATH"`
}

func rcDisplay() string {
	if rc, ok := shellRc(); ok {
		return displayPath(rc)
	}
	return "your shell's startup file"
}

// An agent whose shell can't find guise-gh reaches for plain gh, which is the
// human's login -- so a PATH without binDir gets more than a warning.
func pathCallout() {
	if binDirOnPath() {
		return
	}
	say("")
	say("!!  " + displayPath(binDir) + " is not on your PATH, so guise-gh and guise won't be found")
	say("    -- and an agent that can't find guise-gh falls back to plain gh, as YOU.")
	say("    Add this line to " + rcDisplay() + ", then open a new shell:")
	say("")
	say("        " + pathLine())
}

func installHook() {
	mkdirAll(hooksDir, 0o755)
	mkdirAll(dispatchDir, 0o755)
	writeFile(filepath.Join(hooksDir, "prepare-commit-msg"), hookShim(), 0o755)
	body := dispatcherShim()
	for _, h := range gitHooks {
		writeFile(filepath.Join(dispatchDir, h), body, 0o755)
	}
}

// The rc an interactive shell of this kind actually reads. macOS terminals
// start bash as a login shell, which reads .bash_profile and never .bashrc.
func shellRc() (string, bool) {
	switch filepath.Base(os.Getenv("SHELL")) {
	case "zsh":
		zdot := os.Getenv("ZDOTDIR")
		if zdot == "" {
			zdot = home
		}
		return filepath.Join(zdot, ".zshrc"), true
	case "bash":
		if runtime.GOOS == "darwin" {
			return filepath.Join(home, ".bash_profile"), true
		}
		return filepath.Join(home, ".bashrc"), true
	}
	return "", false
}

// Guarded so that a config dir removed by hand leaves a dead line, not a
// shell that errors on every prompt.
func shellBlock() string {
	rel := filepath.ToSlash(strings.TrimPrefix(shellHookPath, home+string(filepath.Separator)))
	return markStart + "\n[ -f \"$HOME/" + rel + "\" ] && . \"$HOME/" + rel + "\"\n" + markEnd
}

func installShellHook() {
	writeShellHook()
	rc, ok := shellRc()
	if !ok {
		shell := os.Getenv("SHELL")
		if shell == "" {
			shell = "none"
		}
		warn("unrecognized shell '" + shell + "' -- source " + displayPath(shellHookPath) + " from your shell rc to get 'guise use'")
		return
	}
	// A no-op when the line is already there and current, so re-running
	// setup never stacks up copies.
	ensureMarkedBlock(rc, shellBlock())
}

// What update does instead: the rc line is only refreshed where it already
// is, since deleting it is how someone turns the hook down.
func refreshShellHook() bool {
	writeShellHook()
	rc, ok := shellRc()
	if !ok || !isFile(rc) || !hasMarkers(rc) {
		return false
	}
	ensureMarkedBlock(rc, shellBlock())
	return true
}

func writeShellHook() {
	mkdirAll(configDir, 0o755)
	writeFile(shellHookPath, shellHook, 0o644)
}

// Uninstall can run under a different shell than setup did, so clear every
// rc the block could have landed in rather than only this shell's.
func removeShellHook() {
	zdot := os.Getenv("ZDOTDIR")
	if zdot == "" {
		zdot = home
	}
	for _, rc := range []string{
		filepath.Join(zdot, ".zshrc"), filepath.Join(home, ".zshrc"),
		filepath.Join(home, ".bashrc"), filepath.Join(home, ".bash_profile"),
	} {
		removeMarkedBlock(rc)
	}
}

// Never overwrites user edits.
func installAgentDocs(base string) {
	if !exists(filepath.Join(base, "AGENTS.md")) {
		writeFile(filepath.Join(base, "AGENTS.md"), agentsMD, 0o644)
	}
	if !exists(filepath.Join(base, "CLAUDE.md")) {
		writeFile(filepath.Join(base, "CLAUDE.md"), "@AGENTS.md\n", 0o644)
	}
}

func renderIdentityConf(name string) {
	if isUser(name) {
		if !cfgHas("identity." + name + ".login") {
			die("identity '" + name + "' missing login")
		}
		if !cfgHas("identity." + name + ".userid") {
			die("identity '" + name + "' missing user id")
		}
	} else {
		if !cfgHas("identity." + name + ".slug") {
			die("identity '" + name + "' missing slug")
		}
		if !cfgHas("identity." + name + ".botuserid") {
			die("identity '" + name + "' missing botuserid")
		}
	}
	mkdirAll(renderDir, 0o755)
	signing, signingkey := signingOffBlock, ""
	if signingEnabled(name) {
		key := signingKey(name)
		if !isFile(key) || !isFile(key+".pub") {
			die("identity '" + name + "' signs commits but its key is gone from " + key + " -- re-run 'guise setup --sign'")
		}
		signing = signingOnBlock(gitConfigQuote(gitPath(allowedSigners(name))))
		signingkey = "\n\tsigningkey = " + gitConfigQuote(gitPath(key))
		// namespaces="git" stops this key vouching for anything but commits
		// and tags, which is all it is ever asked to sign.
		writeFile(allowedSigners(name), gitEmail(name)+" namespaces=\"git\" "+pubkeyBody(key+".pub")+"\n", 0o644)
	} else {
		_ = os.Remove(allowedSigners(name))
	}
	tmpl := agentConfTemplate
	tmpl = strings.ReplaceAll(tmpl, "{{GIT_NAME}}", gitName(name))
	tmpl = strings.ReplaceAll(tmpl, "{{GIT_EMAIL}}", gitEmail(name))
	tmpl = strings.ReplaceAll(tmpl, "{{SIGNINGKEY}}", signingkey)
	tmpl = strings.ReplaceAll(tmpl, "{{SIGNING}}", signing)
	tmpl = strings.ReplaceAll(tmpl, "{{NAME}}", name)
	// A shell snippet, so a path with a space in it reaches the shell as one
	// word. Without the !, git reads anything not starting with / as a helper
	// name and runs git credential-<it>. Quoted again for the config parser,
	// which rejects the \' a shell-quoted apostrophe carries.
	helper := "!" + shellQuote(gitPath(filepath.Join(binDir, "guise-credential"))) + " " + name
	tmpl = strings.ReplaceAll(tmpl, "{{CREDENTIAL_HELPER}}", gitConfigQuote(helper))
	tmpl = strings.ReplaceAll(tmpl, "{{DISPATCH_DIR}}", gitConfigQuote(gitPath(dispatchDir)))
	writeFile(filepath.Join(renderDir, name+".conf"), tmpl, 0o644)
}

// Regenerate the file we own: one includeIf block per identity. ~/.gitconfig
// itself only ever holds a single [include] pointing here.
func regenOwnedGitconfig() {
	var b strings.Builder
	b.WriteString("# Generated by guise -- do not hand-edit; re-run 'guise setup' instead.\n")
	for _, name := range listIdentities() {
		b.WriteString("\n[includeIf \"gitdir:" + displayPath(identityDir(name)) + "/\"]\n")
		b.WriteString("\tpath = git/" + name + ".conf\n")
	}
	writeFile(ownedGitconfig, b.String(), 0o644)
}

func includeBlock() string {
	return markStart + "\n[include]\n\tpath = " + displayPath(ownedGitconfig) + "\n" + markEnd
}

func ensureIncludeBlock() { ensureMarkedBlock(filepath.Join(home, ".gitconfig"), includeBlock()) }
func removeIncludeBlock() { removeMarkedBlock(filepath.Join(home, ".gitconfig")) }

// ---------------------------------------------------------------------------
// Marked blocks: both ~/.gitconfig and the shell rc get a block between the
// same markers, so the add-or-replace and the byte-identical removal are
// written once.
// ---------------------------------------------------------------------------

// The file's lines, the way awk counts them: a trailing newline ends the last
// line rather than starting an empty one.
func fileLines(content string) []string {
	if content == "" {
		return nil
	}
	lines := strings.Split(content, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// Whole lines only: a line that merely quotes the marker text -- `echo "# >>>
// guise >>>"` -- is ordinary shell, not wiring.
func hasMarkers(file string) bool {
	content, _ := readFile(file)
	for _, l := range fileLines(content) {
		if l == markStart || l == markEnd {
			return true
		}
	}
	return false
}

// Exactly one complete pair, in order. Anything else -- an orphan marker left
// by a hand edit, a duplicated block -- makes the removal ambiguous, and the
// ambiguity would be resolved by deleting lines the human wrote.
func validMarkers(file string) bool {
	content, _ := readFile(file)
	open, starts, ends := false, 0, 0
	for _, l := range fileLines(content) {
		switch l {
		case markStart:
			if open || starts > 0 {
				return false
			}
			open = true
			starts++
		case markEnd:
			if !open || ends > 0 {
				return false
			}
			open = false
			ends++
		}
	}
	return !open && starts == 1 && ends == 1
}

func checkMarkers(file string) {
	if !hasMarkers(file) {
		return
	}
	if !validMarkers(file) {
		die(displayPath(file) + " has a stray guise marker -- the block is not one clean pair, so it cannot be edited safely. Fix the markers by hand, then re-run.")
	}
}

// Drop the block plus the single blank line setup inserted above it. The
// file's own trailing-newline state has to come back with it, or uninstall
// leaves a file one byte longer than it found.
func withoutMarkedBlock(file string) string {
	content, _ := readFile(file)
	eofNewline := content != "" && strings.HasSuffix(content, "\n")
	var kept []string
	inBlock, ended, post, separator := false, false, false, false
	for _, l := range fileLines(content) {
		switch {
		case l == markStart:
			inBlock = true
			if n := len(kept); n > 0 && kept[n-1] == "" {
				kept = kept[:n-1]
				separator = true
			}
		case l == markEnd:
			inBlock = false
			ended = true
		case inBlock:
		default:
			kept = append(kept, l)
			if ended {
				post = true
			}
		}
	}
	finalNewline := separator
	if post {
		finalNewline = eofNewline
	}
	out := strings.Join(kept, "\n")
	if len(kept) > 0 && finalNewline {
		out += "\n"
	}
	return out
}

// Rewrite in place rather than renaming over the path: dotfiles are routinely
// symlinks into a dotfiles repo, and a rename would swap the link itself for
// a regular file. Writing through the open file follows the link and keeps
// mode and ownership.
func replaceContents(file, content string) {
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		die("could not write " + file + ": " + err.Error())
	}
	if _, err := f.WriteString(content); err != nil {
		die("could not write " + file + ": " + err.Error())
	}
	if err := f.Close(); err != nil {
		die("could not write " + file + ": " + err.Error())
	}
}

func currentBlock(file string) string {
	content, _ := readFile(file)
	var lines []string
	in := false
	for _, l := range fileLines(content) {
		if l == markStart {
			in = true
		}
		if in {
			lines = append(lines, l)
		}
		if l == markEnd {
			in = false
		}
	}
	return strings.Join(lines, "\n")
}

func ensureMarkedBlock(file, block string) {
	if !exists(file) {
		writeFile(file, "", 0o644)
	}
	checkMarkers(file)
	had := hasMarkers(file)
	if had && currentBlock(file) == block {
		return
	}
	// The block is re-appended rather than swapped in place: the end of the
	// file is where a fresh setup puts it anyway, and for ~/.gitconfig it is
	// the position that has to win over anything above it.
	var base string
	if had {
		base = withoutMarkedBlock(file)
	} else {
		base, _ = readFile(file)
	}
	replaceContents(file, base+"\n"+block+"\n")
}

func removeMarkedBlock(file string) {
	if !isFile(file) && !exists(file) {
		return
	}
	if !hasMarkers(file) {
		return
	}
	checkMarkers(file)
	replaceContents(file, withoutMarkedBlock(file))
}
