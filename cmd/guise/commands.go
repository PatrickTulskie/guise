package main

import (
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"strings"
)

// ---------------------------------------------------------------------------
// uninstall
// ---------------------------------------------------------------------------

func cmdUninstall(args []string) {
	yes := false
	// Read while the config still exists -- and every root, not just the
	// shared one, or an identity with a workspace of its own goes unmentioned.
	roots := basedirs()
	for len(args) > 0 {
		switch args[0] {
		case "-y", "--yes":
			yes = true
			args = args[1:]
		default:
			die("uninstall: unknown flag '" + args[0] + "'")
		}
	}
	if !yes && isTerminal(os.Stdin) {
		fmt.Fprint(os.Stderr, "Remove guise wiring (gitconfig include, binaries, config, token cache)? [y/N] ")
		reply, _ := readLine()
		switch strings.TrimSpace(reply) {
		case "y", "Y", "yes":
		default:
			say("aborted")
			os.Exit(0)
		}
	}

	// Read while the config still exists: the public half of a signing key
	// stays on the agent account, and only that account's owner can take it
	// down.
	signed := false
	for _, name := range listIdentities() {
		if signingEnabled(name) {
			signed = true
		}
		restoreRepoHooks(name)
	}

	removeIncludeBlock()
	say("removed guise block from ~/.gitconfig")
	removeShellHook()
	say("removed guise block from your shell rc")

	for _, b := range append(append([]string{}, helpers...), exeName) {
		_ = os.Remove(filepath.Join(binDir, b))
	}
	say("removed binaries from " + binDir)

	// Key files are credentials, same policy as 1Password items: left alone.
	_ = os.Remove(keysDir)
	_ = os.Remove(configFile)
	_ = os.Remove(ownedGitconfig)
	_ = os.RemoveAll(renderDir)
	if isDir(keysDir) {
		say("removed config and git wiring from " + configDir)
	} else {
		_ = os.RemoveAll(configDir)
		say("removed " + configDir + " (config, rendered git confs, hooks)")
	}

	_ = os.RemoveAll(cacheDir)
	say("removed token cache " + cacheDir)

	say("")
	say("left alone (remove yourself if you want them gone):")
	say("  - the 1Password item(s) holding the agent credentials")
	if isDir(keysDir) {
		say("  - private keys / tokens / signing keys in " + keysDir)
	}
	if signed {
		say("  - the public signing key on the agent account (SSH and GPG keys page)")
	}
	for _, b := range roots {
		if b != "" {
			say("  - " + b + " and any clones in it")
		}
	}
	say("your own git identity was never modified and is unchanged")
}

// ---------------------------------------------------------------------------
// setup-hooks -- a repository that pins core.hooksPath of its own
// ---------------------------------------------------------------------------

// A repo-local core.hooksPath wins over the rendered conf's, so in a
// repository whose hook manager keeps its hooks in a tracked directory and
// pins that path, guise's hook never runs. Recording the pinned path and
// pointing the repository at the dispatcher keeps both sets of hooks running.
func setupRepoHooks(repo string) {
	current, _ := git(repo, "config", "--local", "--get", "core.hooksPath")
	if current == "" || current == gitPath(dispatchDir) {
		return
	}
	if _, ok := git(repo, "config", "--local", "guise.innerhookspath", current); !ok {
		die("could not record the hooks path of " + repo)
	}
	if _, ok := git(repo, "config", "--local", "core.hooksPath", gitPath(dispatchDir)); !ok {
		die("could not point " + repo + " at the hook dispatcher")
	}
	say("hooks in " + current + " now run through guise, ahead of its own")
}

// Undo for every clone of an identity whose wiring is going away. Left as it
// is, such a clone would point at a dispatcher that no longer exists, and git
// would silently run no hooks at all.
func restoreRepoHooks(name string) {
	if !isDir(identityDir(name)) {
		return
	}
	for _, dir := range identityClones(name) {
		current, _ := git(dir, "config", "--local", "--get", "core.hooksPath")
		if current != gitPath(dispatchDir) {
			continue
		}
		if inner, ok := git(dir, "config", "--local", "--get", "guise.innerhookspath"); ok {
			git(dir, "config", "--local", "core.hooksPath", inner)
			git(dir, "config", "--local", "--unset", "guise.innerhookspath")
		} else {
			git(dir, "config", "--local", "--unset", "core.hooksPath")
		}
		say("handed " + dir + " its own hooks path back")
	}
}

func cmdSetupHooks(args []string) {
	if len(args) > 0 {
		die("setup-hooks takes no arguments")
	}
	requireConfig()
	top, ok := git("", "rev-parse", "--show-toplevel")
	if !ok {
		die("setup-hooks: not inside a git repository")
	}
	name, ok := identityFromCwd()
	if !ok {
		die(cwd() + " belongs to no identity -- setup-hooks is for agent clones under " + basedir("") + "/<identity>/")
	}
	before, _ := git("", "config", "--local", "--get", "core.hooksPath")
	setupRepoHooks(top)
	after, _ := git("", "config", "--local", "--get", "core.hooksPath")
	if before != after {
		return
	}
	inner, ok := git("", "config", "--local", "--get", "guise.innerhookspath")
	if !ok {
		inner = ".git/hooks"
	}
	say("nothing to do: hooks in " + inner + " already run first, then guise's (identity '" + name + "')")
}

// ---------------------------------------------------------------------------
// clone
// ---------------------------------------------------------------------------

func cmdClone(args []string) {
	repo, name := "", ""
	for len(args) > 0 {
		switch {
		case args[0] == "--name":
			if len(args) < 2 {
				die("clone: --name needs a value")
			}
			name = args[1]
			args = args[2:]
		case strings.HasPrefix(args[0], "-"):
			die("clone: unknown flag '" + args[0] + "'")
		default:
			repo = args[0]
			args = args[1:]
		}
	}
	if repo == "" {
		die("usage: guise clone <owner/repo | https url> [--name identity]")
	}
	if !configExists() {
		die("run 'guise setup' first")
	}

	if name == "" {
		name, _ = identityFromCwd()
	}
	if name == "" {
		var ok bool
		name, ok = resolveDefault()
		if !ok {
			die("no default identity set -- pass --name, or set one with 'guise default <name>'")
		}
	}
	if !identityExists(name) {
		die("identity '" + name + "' not in config")
	}

	var url string
	switch {
	case strings.HasPrefix(repo, "https://"):
		url = repo
	case strings.HasPrefix(repo, "git@github.com:"):
		url = "https://github.com/" + strings.TrimPrefix(repo, "git@github.com:")
		warn("rewrote ssh URL to https -- ssh would push as YOU, not the bot")
	case strings.Contains(repo, "/"):
		url = "https://github.com/" + repo + ".git"
	default:
		die("can't parse repo '" + repo + "' -- use owner/repo or an https URL")
	}

	dest := filepath.Join(identityDir(name), strings.TrimSuffix(filepath.Base(url), ".git"))
	if exists(dest) {
		die(dest + " already exists")
	}
	say("cloning into " + dest + " (identity '" + name + "' applies here)")
	if err := runLoud("git", "clone", url, dest); err != nil {
		os.Exit(exitCode(err))
	}
	setupRepoHooks(dest)
	say("done -- work in " + dest + "; use 'guise-gh' instead of 'gh' for PRs")
}

// ---------------------------------------------------------------------------
// update -- reinstall what this binary embeds, and nothing else
// ---------------------------------------------------------------------------

// Everything rewritten here comes from this binary plus the existing config,
// so update reads no credential and calls no API. That is the point: picking
// up a new version must work with the 1Password vault locked and the network
// down. `setup` remains the repair action for anything that needs the
// credential or fresh GitHub metadata.
func cmdUpdate(args []string) {
	if len(args) > 0 {
		die("update takes no arguments")
	}
	requireConfig()
	names := listIdentities()
	if len(names) == 0 {
		die("no identities in config -- run 'guise setup'")
	}

	installBinaries()
	installHook()
	installShellHook()
	say("reinstalled " + strings.Join(helpers, " ") + ", the commit hook, the hook dispatcher, and the shell hook")

	// Every identity, not just the default: a bare `setup` re-renders only
	// the one it ran for, which leaves the others on an old template.
	for _, name := range names {
		renderIdentityConf(name)
	}
	regenOwnedGitconfig()
	ensureIncludeBlock()
	say(fmt.Sprintf("re-rendered %d identity conf(s) in %s", len(names), renderDir))
	pathCallout()
	say("")
	say("config and stored secrets untouched -- run 'guise doctor' to verify the chain")
}

// ---------------------------------------------------------------------------
// which -- the identity owning the current directory
// ---------------------------------------------------------------------------

// The guise-gh helper's identity resolution, and a straight answer to "who
// am I about to act as here?". Exits 1 outside every agent directory.
func cmdWhich(args []string) {
	if len(args) > 0 {
		die("which takes no arguments")
	}
	requireConfig()
	name, ok := identityFromCwd()
	if !ok {
		die(cwd() + " belongs to no identity -- agent clones live under " + basedir("") + "/<identity>/")
	}
	say(name)
}

// ---------------------------------------------------------------------------
// list -- every identity at a glance
// ---------------------------------------------------------------------------

// "What do I have, and which one do commands fall back to?" Columns are
// sized from the rows, so a long identity name doesn't shear the table.
func cmdList(args []string) {
	if len(args) > 0 {
		die("list takes no arguments")
	}
	requireConfig()
	names := listIdentities()
	if len(names) == 0 {
		die("no identities in config -- run 'guise setup'")
	}
	// What `clone` and `use` would actually fall back to, which is not
	// always what the config records.
	def, _ := resolveDefault()

	nw, aw := 8, 7
	for _, name := range names {
		if width(name) > nw {
			nw = width(name)
		}
		if a := width(identityAccount(name)); a > aw {
			aw = a
		}
	}
	fmt.Printf("  %-*s  %-4s  %-*s  %-8s  %s\n", nw, "IDENTITY", "KIND", aw, "ACCOUNT", "STORE", "WORKSPACE")
	for _, name := range names {
		mark := " "
		if name == def {
			mark = "*"
		}
		fmt.Printf("%s %-*s  %-4s  %-*s  %-8s  %s\n", mark, nw, name, identityKind(name), aw, identityAccount(name),
			keySource(name), displayPath(identityDir(name)))
	}
	say("")
	say("'*' marks the default -- what commands fall back to with no name and no agent directory to read")
}

// ---------------------------------------------------------------------------
// basedir -- move a workspace directory after the fact
// ---------------------------------------------------------------------------

// Same shape as `update`: config plus this binary's own output, so no
// credential is read and no API called. What makes this more than a config
// edit is the clones -- a directory left behind under the old path falls out
// of includeIf scope and starts committing as the human, which is the one
// failure this tool exists to prevent. So the directories move with the
// setting, and a destination that is already occupied stops the whole thing.
func cmdBasedir(args []string) {
	path, name := "", ""
	clear := false
	for len(args) > 0 {
		switch {
		case args[0] == "--name":
			if len(args) < 2 {
				die("basedir: --name needs a value")
			}
			name = args[1]
			args = args[2:]
		case args[0] == "--unset":
			clear = true
			args = args[1:]
		case strings.HasPrefix(args[0], "-"):
			die("basedir: unknown flag '" + args[0] + "'")
		default:
			if path != "" {
				die("basedir: too many arguments")
			}
			path = args[0]
			args = args[1:]
		}
	}
	requireConfig()
	if name != "" && !identityExists(name) {
		die("identity '" + name + "' not in config (have: " + identityList() + ")")
	}

	if path == "" && !clear {
		say(basedir(name))
		return
	}
	if clear && path != "" {
		die("basedir: --unset takes no path")
	}
	if clear && name == "" {
		die("basedir: --unset needs --name -- the shared workspace always has a value")
	}

	if path != "" {
		switch {
		case path == "~":
			path = home
		case strings.HasPrefix(path, "~/"):
			path = filepath.Join(home, path[2:])
		case filepath.IsAbs(path):
		default:
			die("basedir: '" + path + "' must be an absolute path (it becomes an includeIf gitdir)")
		}
		path = trimTrailingSep(path)
	}

	// Which identities move, and where to. A per-identity change moves that
	// one; a change to the shared setting moves everyone still falling back
	// to it.
	var targets []string
	if name != "" {
		targets = []string{name}
	} else {
		for _, n := range listIdentities() {
			if !cfgHas("identity." + n + ".basedir") {
				targets = append(targets, n)
			}
		}
	}

	// Every move resolved and validated before any of them runs: a refusal
	// halfway through would leave the workspace split across two roots.
	newroot := path
	if clear {
		newroot = basedir("")
	}
	type move struct{ src, dst string }
	var moves []move
	for _, n := range targets {
		src := identityDir(n)
		dst := filepath.Join(newroot, n)
		if src == dst {
			continue
		}
		if exists(dst) {
			die(dst + " already exists -- move it aside first (nothing changed)")
		}
		if exists(src) && !isDir(src) {
			die(src + " is not a directory (nothing changed)")
		}
		moves = append(moves, move{src, dst})
	}

	// Two ways a plan eats itself, both of which strand half the workspace
	// under the wrong identity while the config still says the old thing.
	// Resolved, not compared as typed: a symlinked root points inside a tree
	// it does not lexically sit in, and the move follows the link while a
	// string compare does not.
	sep := string(filepath.Separator)
	cnewroot := canonicalPath(newroot)
	for _, m := range moves {
		csrc := canonicalPath(m.src)
		// The new root inside a directory that is itself leaving: the first
		// move lands under a tree the next one then tries to move into itself.
		if strings.HasPrefix(cnewroot+sep, csrc+sep) {
			die("the new workspace resolves inside " + m.src + ", which is moving too -- pick a path outside every identity directory (nothing changed)")
		}
		// An identity that is staying put but lives inside one that is
		// leaving: its clones would ride along and fall out of its own scope.
		for _, other := range listIdentities() {
			odir := canonicalPath(identityDir(other))
			if odir == csrc {
				continue
			}
			if strings.HasPrefix(odir+sep, csrc+sep) {
				die("identity '" + other + "' sits inside " + m.src + ", which is moving -- move '" + other + "' out first (nothing changed)")
			}
		}
	}

	for _, m := range moves {
		if !isDir(m.src) {
			continue
		}
		mkdirAll(filepath.Dir(m.dst), 0o755)
		if err := os.Rename(m.src, m.dst); err != nil {
			die("could not move " + m.src + " to " + m.dst)
		}
		say("moved " + displayPath(m.src) + " -> " + displayPath(m.dst) + " (reopen anything you had open in there)")
	}

	switch {
	case clear:
		cfgUnset("identity." + name + ".basedir")
	case name != "":
		cfgSet("identity."+name+".basedir", gitPath(path))
	default:
		cfgSet("core.basedir", gitPath(path))
	}

	// Only the includeIf paths name the workspace; the rendered confs do not,
	// so they are left alone.
	regenOwnedGitconfig()
	ensureIncludeBlock()
	for _, n := range listIdentities() {
		mkdirAll(identityDir(n), 0o755)
	}
	for _, root := range basedirs() {
		if root != "" {
			installAgentDocs(root)
		}
	}

	if name != "" {
		say("identity '" + name + "' now works out of " + displayPath(identityDir(name)))
	} else {
		say("shared workspace is now " + displayPath(basedir("")))
	}
	say("run 'guise doctor' to verify the chain")
}

// ---------------------------------------------------------------------------
// token
// ---------------------------------------------------------------------------

func cmdToken(args []string) {
	ident := ""
	if len(args) > 0 {
		ident = args[0]
	}
	// Empty is fine: the helper resolves the configured default.
	helperToken(ident)
}

// ---------------------------------------------------------------------------
// warm-cache -- prime op-cache before the agents start
// ---------------------------------------------------------------------------

// op-cache only holds what something has already asked it for, so after a
// reboot the first read of an `--store op-cache` identity is the one that
// prompts 1Password -- usually an unattended agent, with nobody there to
// approve it. Reading each of those secrets once, by hand or from a login
// item, moves that prompt to a moment you are present for.
func cmdWarmCache(args []string) {
	only := ""
	for len(args) > 0 {
		switch args[0] {
		case "--name":
			if len(args) < 2 {
				die("warm-cache: --name needs a value")
			}
			only = args[1]
			args = args[2:]
		default:
			die("warm-cache: unknown flag '" + args[0] + "'")
		}
	}
	requireConfig()
	if only != "" {
		if !identityExists(only) {
			die("identity '" + only + "' not in config (have: " + identityList() + ")")
		}
		if keySource(only) != "op-cache" {
			die("identity '" + only + "' reads its secret from " + keySource(only) + ", not op-cache -- nothing to warm")
		}
	}

	warmed, failed := 0, 0
	for _, name := range listIdentities() {
		if only != "" && name != only {
			continue
		}
		if keySource(name) != "op-cache" {
			continue
		}
		// stdout is the secret itself, so it goes nowhere; op's own complaint
		// on stderr is the useful part of a failure.
		if _, err := opRead(name, secretField(name)); err == nil {
			say("warmed '" + name + "' from " + cfgGetOr("identity."+name+".opitem", ""))
			warmed++
		} else {
			warn("could not read '" + name + "' -- " + opHint(name))
			failed++
		}
	}

	if warmed == 0 && failed == 0 {
		say("no identity reads through op-cache -- nothing to warm")
		return
	}
	if failed > 0 {
		die(fmt.Sprintf("%d identity(ies) unread -- the agent that needs one will still prompt", failed))
	}
	say(fmt.Sprintf("%d secret(s) cached for the rest of this login session", warmed))
}

// ---------------------------------------------------------------------------
// default / use
// ---------------------------------------------------------------------------

func cmdDefault(args []string) {
	requireConfig()
	if len(args) == 0 {
		say(defaultIdentity())
		return
	}
	if !identityExists(args[0]) {
		die("identity '" + args[0] + "' not in config (have: " + identityList() + ")")
	}
	cfgSet("core.defaultidentity", args[0])
	say("default identity is now '" + args[0] + "'")
}

// A child process cannot cd its parent, so this replaces itself with a shell
// already sitting in the directory. Leave it the way you leave any shell:
// exit.
func cmdUse(args []string) {
	name, emit := "", false
	for len(args) > 0 {
		switch {
		case args[0] == "--emit-shell":
			emit = true
			args = args[1:]
		case strings.HasPrefix(args[0], "-"):
			die("use: unknown flag '" + args[0] + "'")
		default:
			if name != "" {
				die("use: too many arguments")
			}
			name = args[0]
			args = args[1:]
		}
	}
	requireConfig()

	if name == "" {
		var ok bool
		name, ok = resolveDefault()
		if !ok {
			die("no default identity set -- name one, or set one with 'guise default <name>'")
		}
	}
	if !identityExists(name) {
		die("identity '" + name + "' not in config (have: " + identityList() + ")")
	}

	dir := identityDir(name)
	mkdirAll(dir, 0o755)

	// The identity follows the directory -- git through includeIf, gh
	// through guise-gh reading the cwd -- so landing there is the whole job.
	// Nothing is exported, which is what keeps a later cd out of the tree
	// from carrying a stale identity with it.
	if emit {
		say("cd " + shellQuote(dir))
		return
	}

	if err := os.Chdir(dir); err != nil {
		die("could not enter " + dir)
	}
	say("identity '" + name + "' -- " + displayPath(dir) + "; exit to come back")
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "/bin/sh"
	}
	// Git Bash spells $SHELL as /usr/bin/bash, a path only its own tools
	// resolve; the bare name is on PATH either way.
	if runtime.GOOS == "windows" {
		if _, err := exec.LookPath(shell); err != nil {
			shell = path.Base(shell)
		}
	}
	// PWD as the shell would have set it on a cd: the path as spelled, not
	// as the kernel resolves it.
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "PWD=") {
			env = append(env, kv)
		}
	}
	execReplace(shell, nil, append(env, "PWD="+dir))
}

// ---------------------------------------------------------------------------
// rename
// ---------------------------------------------------------------------------

// Renames an identity and everything named after it: its config section, its
// key file, its rendered git conf, and its directory under the base dir.
func cmdRename(args []string) {
	old, newName := "", ""
	for len(args) > 0 {
		switch {
		case strings.HasPrefix(args[0], "-"):
			die("rename: unknown flag '" + args[0] + "'")
		case old == "":
			old = args[0]
		case newName == "":
			newName = args[0]
		default:
			die("rename: too many arguments")
		}
		args = args[1:]
	}
	if old == "" || newName == "" {
		die("usage: guise rename <old> <new>")
	}
	requireConfig()

	if !nameRe.MatchString(newName) {
		die("identity name must match [A-Za-z0-9_-]+: '" + newName + "'")
	}
	if !identityExists(old) {
		die("identity '" + old + "' not in config")
	}
	if identityExists(newName) {
		die("identity '" + newName + "' already exists")
	}

	src := identityDir(old)
	// The override travels with the name, so the destination is under
	// whatever workspace the old name resolved to.
	dst := filepath.Join(basedir(old), newName)
	if exists(dst) {
		die(dst + " already exists -- move it aside first")
	}

	cfgRenameSection("identity."+old, "identity."+newName)

	// Key material is named after the identity too; keep the two in step.
	for _, key := range []string{"keyfile", "tokenfile"} {
		f, ok := cfgPath("identity." + newName + "." + key)
		if !ok || !isFile(f) {
			continue
		}
		moved := filepath.Join(filepath.Dir(f), newName+filepath.Ext(f))
		if err := os.Rename(f, moved); err != nil {
			die("could not move " + f + " to " + moved)
		}
		cfgSet("identity."+newName+"."+key, gitPath(moved))
	}

	// The signing key is a pair, and the extension rule above would turn
	// <old>.signing.pub into <new>.pub, so it moves separately.
	if signingEnabled(newName) {
		f := signingKey(newName)
		if isFile(f) {
			moved := filepath.Join(keysDir, newName+".signing")
			if err := os.Rename(f, moved); err != nil {
				die("could not move " + f + " to " + moved)
			}
			if isFile(f + ".pub") {
				if err := os.Rename(f+".pub", moved+".pub"); err != nil {
					die("could not move " + f + ".pub")
				}
			}
			cfgSet("identity."+newName+".signingkey", gitPath(moved))
		}
	}

	if isDir(src) {
		if err := os.Rename(src, dst); err != nil {
			die("could not move " + src + " to " + dst)
		}
		say("moved " + src + " -> " + dst + " (reopen anything you had open in there)")
	} else {
		mkdirAll(dst, 0o755)
	}

	_ = os.Remove(filepath.Join(renderDir, old+".conf"))
	_ = os.Remove(filepath.Join(cacheDir, old+".token.json"))
	_ = os.Remove(allowedSigners(old))
	renderIdentityConf(newName)
	regenOwnedGitconfig()
	ensureIncludeBlock()

	if defaultIdentity() == old {
		cfgSet("core.defaultidentity", newName)
		say("default identity is now '" + newName + "'")
	}
	say("renamed identity '" + old + "' to '" + newName + "'")
}

// ---------------------------------------------------------------------------
// cp -- a second workspace for the same identity
// ---------------------------------------------------------------------------

// The new file is never readable by anyone else, not even between the copy
// and the chmod.
func copyKeyFile(src, dst string) {
	data, err := os.ReadFile(src)
	if err != nil {
		die("cannot read " + src)
	}
	f, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		die("could not write " + dst + ": " + err.Error())
	}
	if _, err := f.Write(data); err != nil {
		die("could not write " + dst)
	}
	f.Close()
	chmod(dst, 0o600)
}

// A second set of clones committing as the same account, without a second
// setup: that would read the secret again and, for a signing identity, put a
// new key through the browser step. Everything named after the identity is
// copied so rename, rm --secret and uninstall keep their one assumption --
// an identity owns the files that carry its name. A 1Password item is shared
// instead: same reference, one place to rotate.
func cmdCp(args []string) {
	src, newName := "", ""
	for len(args) > 0 {
		switch {
		case strings.HasPrefix(args[0], "-"):
			die("cp: unknown flag '" + args[0] + "'")
		case src == "":
			src = args[0]
		case newName == "":
			newName = args[0]
		default:
			die("cp: too many arguments")
		}
		args = args[1:]
	}
	if src == "" || newName == "" {
		die("usage: guise cp <identity> <new-name>")
	}
	requireConfig()

	if !nameRe.MatchString(newName) {
		die("identity name must match [A-Za-z0-9_-]+: '" + newName + "'")
	}
	if !identityExists(src) {
		die("identity '" + src + "' not in config")
	}
	if identityExists(newName) {
		die("identity '" + newName + "' already exists")
	}

	// The workspace override is copied with the rest of the section, so the
	// copy lands beside the source.
	dst := filepath.Join(basedir(src), newName)
	if exists(dst) {
		die(dst + " already exists -- move it aside first")
	}

	// Every source file is checked before anything is written, and the
	// config section is written last: it is what makes the name taken, so a
	// failure before it leaves nothing in the way of a retry.
	secret, signkey := "", ""
	if keySource(src) == "file" {
		var ok bool
		secret, ok = secretFile(src)
		if !ok {
			die("identity '" + src + "' has no secret file recorded -- re-run 'guise setup --name " + src + "'")
		}
		if f, err := os.Open(secret); err != nil {
			die("cannot read " + secret + " -- nothing copied")
		} else {
			f.Close()
		}
	}
	if signingEnabled(src) {
		signkey = signingKey(src)
		if !readable(signkey) || !readable(signkey+".pub") {
			die("identity '" + src + "' signs commits but its key is gone from " + signkey + " -- re-run 'guise setup --sign'")
		}
	}

	newSecret, newSignkey := "", ""
	if secret != "" || signkey != "" {
		mkdirAll(keysDir, 0o700)
		chmod(keysDir, 0o700)
	}
	if secret != "" {
		newSecret = filepath.Join(keysDir, newName+filepath.Ext(secret))
		copyKeyFile(secret, newSecret)
	}
	if signkey != "" {
		newSignkey = filepath.Join(keysDir, newName+".signing")
		copyKeyFile(signkey, newSignkey)
		pub, _ := readFile(signkey + ".pub")
		writeFile(newSignkey+".pub", pub, 0o644)
	}

	// git config renames a section but can't copy one.
	for _, key := range cfgKeysUnder("identity." + src + ".") {
		v, _ := cfgGet(key)
		cfgSet("identity."+newName+"."+strings.TrimPrefix(key, "identity."+src+"."), v)
	}
	if newSecret != "" {
		if isUser(newName) {
			cfgSet("identity."+newName+".tokenfile", gitPath(newSecret))
		} else {
			cfgSet("identity."+newName+".keyfile", gitPath(newSecret))
		}
	}
	if newSignkey != "" {
		cfgSet("identity."+newName+".signingkey", gitPath(newSignkey))
	}

	mkdirAll(dst, 0o755)
	renderIdentityConf(newName)
	regenOwnedGitconfig()
	ensureIncludeBlock()

	say("copied identity '" + src + "' to '" + newName + "' -- both commit as " + identityAccount(src))
	if newSecret != "" {
		say("    its " + strings.ReplaceAll(secretField(newName), "_", " ") + " is a copy at " + newSecret + "; 'guise rm " + newName + " --secret' shreds only that one")
	} else {
		say("    both read the same 1Password item (" + cfgGetOr("identity."+newName+".opitem", "") + ") -- rotate it once")
	}
	if newSignkey != "" {
		say("    commits sign with the same key, copied to " + newSignkey + " -- already on the account")
	}
	say("    agent clones go in " + dst + "/ (use 'guise clone <owner/repo> --name " + newName + "')")
}

func readable(p string) bool {
	f, err := os.Open(p)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

// ---------------------------------------------------------------------------
// rm -- remove one identity
// ---------------------------------------------------------------------------

// One clone per entry, none once the directory is gone.
func identityClones(name string) []string {
	dir := identityDir(name)
	if !isDir(dir) {
		return nil
	}
	return sortUnique(reposUnder(dir, 2))
}

// Clones holding work that exists nowhere else: uncommitted changes, or
// commits no remote branch has -- on a local branch or a detached HEAD.
func unsavedClones(name string) []string {
	var out []string
	for _, dir := range identityClones(name) {
		status, _ := git(dir, "status", "--porcelain")
		unpushed, _ := git(dir, "log", "-1", "--format=%h", "HEAD", "--branches", "--not", "--remotes")
		if status != "" || unpushed != "" {
			out = append(out, dir)
		}
	}
	return out
}

// Workspaces may nest, so deleting one identity's directory can take
// another's with it. Resolved first: a workspace reached through a symlink
// is nested all the same.
func identityNestedIn(name string) (string, bool) {
	sep := string(filepath.Separator)
	dir := canonicalPath(identityDir(name))
	for _, other := range listIdentities() {
		if other == name {
			continue
		}
		if strings.HasPrefix(canonicalPath(identityDir(other))+sep, dir+sep) {
			return other, true
		}
	}
	return "", false
}

type rmState struct {
	name                        string
	code, secret, signing, keep bool
}

func cmdRm(args []string) {
	r := &rmState{}
	wizard, flags := false, false
	for len(args) > 0 {
		switch {
		case args[0] == "--code":
			r.code, flags = true, true
		case args[0] == "--secret":
			r.secret, flags = true, true
		case args[0] == "--signing-key":
			r.signing, flags = true, true
		case args[0] == "--force":
			r.code, r.secret, r.signing, flags = true, true, true, true
		case args[0] == "--keep":
			r.keep, flags = true, true
		case args[0] == "--wizard":
			wizard = true
		case strings.HasPrefix(args[0], "-"):
			die("rm: unknown flag '" + args[0] + "'")
		default:
			if r.name != "" {
				die("rm: too many arguments")
			}
			r.name = args[0]
		}
		args = args[1:]
	}
	requireConfig()
	if r.keep && (r.code || r.secret || r.signing) {
		die("rm: --keep removes the wiring and nothing else, so it can't join --code, --secret, --signing-key or --force")
	}
	if r.name != "" && !identityExists(r.name) {
		die("identity '" + r.name + "' not in config")
	}

	if !wizard && !flags {
		if !isTerminal(os.Stdin) {
			die("rm: no terminal to ask on, so say what goes -- --keep (the wiring only), --code, --secret, --signing-key, or --force (all of it)")
		}
		wizard = true
	}
	wz.cmd = "rm"
	// The wizard warns about unpushed work before it asks; a --code flag
	// skips that question, so the warning has to come from here instead.
	flaggedCode := r.code
	if wizard {
		r.wzRm()
	}
	if r.name == "" {
		die("usage: guise rm <identity> [--keep | --code --secret --signing-key | --force]")
	}
	name := r.name

	dir := identityDir(name)
	var unsaved []string
	if flaggedCode {
		unsaved = unsavedClones(name)
	}
	keyfile, _ := secretFile(name)
	signkey := signingKey(name)
	if r.code {
		if nested, ok := identityNestedIn(name); ok {
			die("identity '" + nested + "' lives inside " + dir + " -- move it with 'guise basedir' or remove it first")
		}
	}
	inOp := opBacked(keySource(name))
	wasDefault := defaultIdentity() == name

	if !r.code {
		restoreRepoHooks(name)
	}
	cfgRemoveSection("identity." + name)
	// Recorded before any cleanup that can fail, so a shred that aborts the
	// run does not also drop the clones out of doctor's view.
	if isDir(dir) {
		strandedRecord(dir)
	}
	_ = os.Remove(filepath.Join(renderDir, name+".conf"))
	_ = os.Remove(filepath.Join(cacheDir, name+".token.json"))
	_ = os.Remove(allowedSigners(name))
	regenOwnedGitconfig()
	say("removed identity '" + name + "' (config, git wiring, token cache)")

	if wasDefault {
		cfgUnset("core.defaultidentity")
		left := listIdentities()
		switch len(left) {
		case 1:
			cfgSet("core.defaultidentity", left[0])
			say("default identity is now '" + left[0] + "'")
		case 0:
		default:
			say("no default identity now -- pick one with 'guise default <name>'")
		}
	}

	if r.secret && keyfile != "" && isFile(keyfile) {
		mustShred(keyfile)
		say("shredded " + keyfile)
	}
	if r.signing && (isFile(signkey) || isFile(signkey+".pub")) {
		say("signing key:")
		shredSigningKey(signkey)
	}
	if r.code && isDir(dir) {
		if len(unsaved) > 0 {
			warn("deleting work that isn't pushed anywhere:")
			for _, u := range unsaved {
				fmt.Fprintln(os.Stderr, "  "+u)
			}
		}
		if err := os.RemoveAll(dir); err != nil {
			die("could not delete " + dir + ": " + err.Error())
		}
		strandedForget(dir)
		say("deleted " + dir)
	}

	var kept []string
	if inOp {
		kept = append(kept, "  - the 1Password item holding its credential")
	}
	if keyfile != "" && isFile(keyfile) {
		kept = append(kept, "  - "+keyfile)
	}
	if isFile(signkey) {
		kept = append(kept, "  - "+signkey+", and its public half on the agent account")
	}
	if isDir(dir) {
		kept = append(kept, "  - "+dir+" -- clones in it now commit as you; 'guise doctor' lists them")
	}
	if len(kept) > 0 {
		say("")
		say("left alone (remove yourself if you want them gone):")
		for _, k := range kept {
			say(k)
		}
	}
}
