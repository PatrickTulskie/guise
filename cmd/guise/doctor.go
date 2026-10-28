package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var doctorFailures int

func check(desc, hint string, ok bool) {
	if ok {
		fmt.Printf("  ok    %s\n", desc)
		return
	}
	fmt.Printf("  FAIL  %s\n", desc)
	fmt.Printf("        hint: %s\n", hint)
	doctorFailures++
}

// Same shape as check(), but does not count towards the exit status. For
// things that are worth telling someone about without calling the install
// broken -- the shell hook is a convenience, and declining it is a
// legitimate choice.
func note(desc, hint string, ok bool) {
	if ok {
		fmt.Printf("  ok    %s\n", desc)
		return
	}
	fmt.Printf("  warn  %s\n", desc)
	fmt.Printf("        hint: %s\n", hint)
}

func anyIdentity(pred func(name string) bool) bool {
	for _, n := range listIdentities() {
		if pred(n) {
			return true
		}
	}
	return false
}

func chkDeps() bool {
	for _, c := range []string{"gh", "git", "curl"} {
		if !have(c) {
			return false
		}
	}
	if anyIdentity(func(n string) bool { return cfgHas("identity." + n + ".signing") }) && !have("ssh-keygen") {
		return false
	}
	if anyIdentity(func(n string) bool { return keySource(n) == "op-cache" }) && !have("op-cache") {
		return false
	}
	return true
}

func chkOp(name, field string) bool {
	if !have(opReader(name)) {
		return false
	}
	_, err := opReadTo(name, field, io.Discard)
	return err == nil
}

func chkOpPinned(name string) bool { return cfgHas("identity." + name + ".opaccount") }

// What to do when an identity's 1Password secret can't be read.
func opHint(name string) string {
	s := ""
	if keySource(name) == "op-cache" {
		s = "install op-cache (brew install PatrickTulskie/tap/op-cache), "
	}
	return s + "op signin, or if " + cfgGetOr("identity."+name+".opitem", "") + " moved: guise setup --name " + name + " --op-item op://<vault>/<item>"
}

func chkKeyfile(name string) bool {
	f, ok := cfgPath("identity." + name + ".keyfile")
	if !ok || !isFile(f) || !mode600(f) {
		return false
	}
	data, err := os.ReadFile(f)
	return err == nil && validPrivateKey(data)
}

func chkTokenfile(name string) bool {
	f, ok := cfgPath("identity." + name + ".tokenfile")
	return ok && isNonEmptyFile(f) && mode600(f)
}

// The installed helper, the one git and guise-gh run -- so what doctor
// proves is the install, not this process.
func installedToken(name string) (string, bool) {
	out, err := runShimOutput(filepath.Join(binDir, "guise-token"), name)
	return out, err == nil
}

var ghsRe = regexp.MustCompile(`^ghs_`)
var patRe = regexp.MustCompile(`^(github_pat_|ghp_)`)

func chkToken(name string) bool {
	t, ok := installedToken(name)
	if !ok {
		return false
	}
	if isUser(name) {
		return patRe.MatchString(t)
	}
	return ghsRe.MatchString(t)
}

func chkCache(name string) bool {
	a, ok1 := installedToken(name)
	b, ok2 := installedToken(name)
	return ok1 && ok2 && a == b && isFile(filepath.Join(cacheDir, name+".token.json"))
}

// The inverse for an account: guise-token caches only minted App tokens, so a
// cache file under a PAT identity's name is a second copy of a standing
// credential that nothing in guise wrote.
func chkNoPatCache(name string) bool {
	if _, ok := installedToken(name); !ok {
		return false
	}
	return !exists(filepath.Join(cacheDir, name+".token.json"))
}

var botEmailRe = regexp.MustCompile(`^[0-9]+\+.*\[bot\]@users\.noreply\.github\.com$`)
var userEmailRe = regexp.MustCompile(`^[0-9]+\+[^@]+@users\.noreply\.github\.com$`)

func chkEmailFormat(name string) bool {
	if isUser(name) {
		return userEmailRe.MatchString(gitEmail(name))
	}
	return botEmailRe.MatchString(gitEmail(name))
}

func chkBotReal(name string) bool {
	body, err := curlGet(githubAPI + "/users/" + cfgGetOr("identity."+name+".slug", "") + "%5Bbot%5D")
	if err != nil {
		return false
	}
	return jsonString(jsonField(jsonParse(body), "id")) == cfgGetOr("identity."+name+".botuserid", "")
}

func chkIdsDiffer(name string) bool {
	return cfgGetOr("identity."+name+".appid", "") != cfgGetOr("identity."+name+".botuserid", "")
}

// One authenticated call as the identity itself. Works for both kinds:
// guise-token mints an installation token for apps and returns the PAT for
// accounts.
func curlAsIdentity(name string, args ...string) (string, bool) {
	t, ok := installedToken(name)
	if !ok {
		return "", false
	}
	out, err := githubCurl(t, args...)
	return out, err == nil
}

func apiAsIdentity(name, path string) (string, bool) { return curlAsIdentity(name, githubAPI+path) }

// A PAT for an account in a SAML SSO org works everywhere else until it is
// authorized for that org: GitHub answers list calls without the org's repos
// and 403s anything inside it, saying so only in a response header.
func chkSSOAuthorized(name string) bool {
	hdr, err := os.CreateTemp("", "guise-hdr")
	if err != nil {
		return false
	}
	hdr.Close()
	defer os.Remove(hdr.Name())
	_, ok := curlAsIdentity(name, "-D", hdr.Name(), githubAPI+"/user/repos?per_page=1")
	content, _ := readFile(hdr.Name())
	for _, line := range strings.Split(content, "\n") {
		if strings.HasPrefix(lower(line), "x-github-sso:") {
			return false
		}
	}
	return ok
}

// The PAT still works AND still belongs to the account we recorded -- a
// swapped token would otherwise silently change who the agent is.
func chkUserReal(name string) bool {
	body, ok := apiAsIdentity(name, "/user")
	if !ok {
		return false
	}
	user := jsonParse(body)
	return jsonString(jsonField(user, "id")) == cfgGetOr("identity."+name+".userid", "") &&
		lower(jsonString(jsonField(user, "login"))) == lower(cfgGetOr("identity."+name+".login", ""))
}

// A credential can be entirely valid and still reach zero repositories,
// which otherwise surfaces only as a 403 at clone time.
func chkReachesRepo(name string) bool {
	var n string
	if isUser(name) {
		body, ok := apiAsIdentity(name, "/user/repos?per_page=1")
		if !ok {
			return false
		}
		n = strconv.Itoa(len(jsonArray(body)))
	} else {
		body, ok := apiAsIdentity(name, "/installation/repositories?per_page=1")
		if !ok {
			return false
		}
		n = jsonString(jsonField(jsonParse(body), "total_count"))
	}
	count, err := strconv.Atoi(n)
	return err == nil && count > 0
}

// PATs expire; installation tokens are minted on demand. Warn while there is
// still time to rotate. Only the date part is compared: hours don't matter
// at 30 days.
func chkTokenFresh(name string) bool {
	exp, ok := cfgGet("identity." + name + ".tokenexpires")
	if !ok {
		return true
	}
	cutoff := time.Now().UTC().AddDate(0, 0, 30).Format("2006-01-02")
	if len(exp) > 10 {
		exp = exp[:10]
	}
	return exp > cutoff
}

func chkNotHuman(name string) bool {
	human, ok := humanLogin()
	if !ok {
		return true
	}
	return lower(human) != lower(cfgGetOr("identity."+name+".login", ""))
}

// Runs fn with a repo inside the identity's scope.
func withScopedRepo(name string, fn func(repo string) bool) bool {
	if !isDir(identityDir(name)) {
		return false
	}
	dir, err := os.MkdirTemp(identityDir(name), ".doctor.")
	if err != nil {
		return false
	}
	defer os.RemoveAll(dir)
	repo := filepath.Join(dir, "repo")
	if _, ok := git("", "init", "-q", repo); !ok {
		return false
	}
	return fn(repo)
}

func chkIncludeIf(name string) bool {
	return withScopedRepo(name, func(repo string) bool {
		origin, _ := git(repo, "config", "--show-origin", "--get", "user.email")
		email, _ := git(repo, "config", "--get", "user.email")
		return strings.Contains(origin, "/git/"+name+".conf") && email == gitEmail(name)
	})
}

func chkGpgsign(name string) bool {
	return withScopedRepo(name, func(repo string) bool {
		v, _ := git(repo, "config", "--get", "commit.gpgsign")
		return v == "false"
	})
}

func chkSigningKey(name string) bool {
	k := signingKey(name)
	// Anything looser than 600 and another local account can sign as the agent.
	return isFile(k) && isFile(k+".pub") && mode600(k)
}

func chkSigningRegistered(name string) bool {
	k := signingKey(name)
	if !isFile(k + ".pub") {
		return false
	}
	return keyRegistered(cfgGetOr("identity."+name+".login", ""), k+".pub")
}

// Resolved inside agent scope, so a later include that overrides either one
// is caught too. A signingkey that is not guise's own file -- a public-key
// literal, say -- would route signing to an ssh-agent, which holds the
// human's keys.
func chkSigningProgram(name string) bool {
	return withScopedRepo(name, func(repo string) bool {
		v, _ := git(repo, "config", "--get", "gpg.ssh.program")
		return v == "ssh-keygen"
	})
}

func chkSigningkeyPath(name string) bool {
	return withScopedRepo(name, func(repo string) bool {
		v, _ := git(repo, "config", "--get", "user.signingkey")
		return v == gitPath(signingKey(name))
	})
}

// End to end rather than by inspection: make a real commit inside agent scope
// and verify it against the rendered allowed-signers file.
func chkSigns(name string) bool {
	return withScopedRepo(name, func(repo string) bool {
		if _, ok := git(repo, "commit", "-q", "--allow-empty", "-m", "guise doctor"); !ok {
			return false
		}
		_, ok := git(repo, "verify-commit", "HEAD")
		return ok
	})
}

func chkCredential(name string) bool {
	return withScopedRepo(name, func(repo string) bool {
		cmd := exec.Command("git", "-C", repo, "credential", "fill")
		cmd.Stdin = strings.NewReader("protocol=https\nhost=github.com\n\n")
		cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_ASKPASS=/usr/bin/false")
		out, _ := cmd.Output()
		for _, line := range strings.Split(string(out), "\n") {
			if line == "username=x-access-token" {
				return true
			}
		}
		return false
	})
}

func chkHumanUntouched() bool {
	dir, err := os.MkdirTemp("", "guise-doctor")
	if err != nil {
		return false
	}
	defer os.RemoveAll(dir)
	repo := filepath.Join(dir, "repo")
	if _, ok := git("", "init", "-q", repo); !ok {
		return false
	}
	email, _ := git(repo, "config", "--get", "user.email")
	gemail, _ := git("", "config", "--global", "--get", "user.email")
	sign, _ := git(repo, "config", "--get", "commit.gpgsign")
	gsign, _ := git("", "config", "--global", "--get", "commit.gpgsign")
	return email == gemail && sign == gsign
}

func chkHook() bool { return isExecutable(filepath.Join(hooksDir, "prepare-commit-msg")) }

func chkDispatcher() bool {
	for _, h := range gitHooks {
		if !isExecutable(filepath.Join(dispatchDir, h)) {
			return false
		}
	}
	return true
}

func chkHooksPath(name string) bool {
	return withScopedRepo(name, func(repo string) bool {
		v, _ := git(repo, "config", "--get", "core.hooksPath")
		return v == gitPath(dispatchDir)
	})
}

// The repository doctor runs in, when an identity owns it: a path the repo
// pins itself wins over the conf, so this reads what git resolves.
func chkRepoHooksPath() bool {
	v, _ := git("", "config", "--get", "core.hooksPath")
	return v == gitPath(dispatchDir)
}

func inAgentRepo() bool {
	if _, ok := git("", "rev-parse", "--show-toplevel"); !ok {
		return false
	}
	_, ok := identityFromCwd()
	return ok
}

func chkShellHook() bool {
	if !isFile(shellHookPath) {
		return false
	}
	rc, ok := shellRc()
	if !ok {
		return false
	}
	content, _ := readFile(rc)
	for _, l := range fileLines(content) {
		if l == markStart {
			return true
		}
	}
	return false
}

func chkBinaries() bool {
	for _, b := range helpers {
		if !isExecutable(filepath.Join(binDir, b)) {
			return false
		}
	}
	return true
}

// Proved against the installed copy: a guise-gh written before it checked the
// token hands gh an empty GH_TOKEN when guise-token fails, and gh then runs
// as whoever is logged in. A config that isn't there makes the token fail; a
// gh that only leaves a marker says whether it ran.
func chkGhFailsClosed() bool {
	dir, err := os.MkdirTemp("", "guise-doctor")
	if err != nil {
		return false
	}
	defer os.RemoveAll(dir)
	writeFile(filepath.Join(dir, "gh"), "#!/bin/sh\ntouch "+shellQuote(filepath.Join(dir, "ran"))+"\n", 0o755)
	cmd := shimCommand(filepath.Join(binDir, "guise-gh"), "--version")
	cmd.Env = append(os.Environ(),
		"PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"),
		"GUISE_CONFIG="+filepath.Join(dir, "no-config"),
		"GUISE_IDENTITY=doctor")
	err = cmd.Run()
	return err != nil && !exists(filepath.Join(dir, "ran"))
}

// A hand edit or an identity removed by an older version can leave the
// default naming nothing. resolveDefault covers that while there is one
// identity to fall back on; with more, clone and use die.
func chkDefaultExists() bool {
	d, ok := cfgGet("core.defaultidentity")
	if !ok {
		return true
	}
	return identityExists(d)
}

// What a shell calling name would run. Aliases are invisible to a
// non-interactive bash, but an exported function is imported and wins over
// any file, so doctor sees it the way the agent's shell does.
func resolveCmd(name string) string {
	if os.Getenv("BASH_FUNC_"+name+"%%") != "" || os.Getenv("BASH_FUNC_"+name+"()") != "" {
		return "function"
	}
	// LookPath on Windows matches only PATHEXT names, and the shims have no
	// extension; sh finds them by name, so this does too.
	if runtime.GOOS == "windows" {
		for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
			for _, n := range []string{name, name + ".exe"} {
				if p := filepath.Join(dir, n); isFile(p) {
					return p
				}
			}
		}
		return ""
	}
	p, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return p
}

func chkHelpersResolve() bool {
	for _, b := range helpers {
		found := resolveCmd(b)
		if found == "" || found == "function" || !sameFile(found, filepath.Join(binDir, b)) {
			return false
		}
	}
	return true
}

func helpersHint() string {
	if !binDirOnPath() {
		return displayPath(binDir) + " is not on PATH -- add this to " + rcDisplay() + ", then open a new shell:  " + pathLine()
	}
	for _, b := range helpers {
		found := resolveCmd(b)
		installed := filepath.Join(binDir, b)
		switch found {
		case "":
			return installed + " is missing -- run 'guise update'"
		case "function":
			return "a shell function named " + b + " shadows " + installed + " -- unset -f " + b + ", and take its definition (and any export -f) out of your shell config"
		}
		if !sameFile(found, installed) {
			return found + " shadows " + installed + " -- remove it, or put " + tildePath(binDir) + " ahead of " + tildePath(filepath.Dir(found)) + " on PATH"
		}
	}
	return ""
}

func chkGuiseOnPath() bool {
	_, err := exec.LookPath("guise")
	return err == nil
}

func guisePathHint() string {
	if binDirOnPath() {
		return displayPath(binDir) + "/guise is missing -- run './bin/guise update' from a checkout to reinstall it"
	}
	return "add this to " + rcDisplay() + ", then open a new shell:  " + pathLine()
}

// The copy an agent runs is whichever `guise` PATH finds, and after an
// upgrade that is often not the one doctor is running from.
func chkGuiseCurrent() bool {
	found, err := exec.LookPath("guise")
	if err != nil {
		return false
	}
	if sameFile(found, exePath) {
		return true
	}
	out, _ := output(found, "--version")
	return out == "guise "+version
}

func guiseVersionHint() string {
	found, err := exec.LookPath("guise")
	if err != nil {
		return "nothing named guise is on PATH -- fix the check above"
	}
	reports, err := output(found, "--version")
	if err != nil {
		reports = "nothing for --version"
	}
	return found + " reports '" + reports + "' and this is guise " + version + " -- run 'guise update' from the newer copy, or remove the stale one"
}

// Every entry named .git within depth levels of root, as the directory that
// holds it. A submodule's or worktree's .git is a file, and either is still a
// repo, so this matches on the name rather than the type.
func reposUnder(root string, depth int) []string {
	var repos []string
	var walk func(dir string, level int)
	walk = func(dir string, level int) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			if e.Name() == ".git" {
				repos = append(repos, dir)
				continue
			}
			if e.IsDir() && level < depth {
				walk(filepath.Join(dir, e.Name()), level+1)
			}
		}
	}
	walk(root, 1)
	return repos
}

// Every repo under root that no identity directory holds. The walk stops at
// an identity directory, where everything is wired, and at a repo root, since
// what sits inside a clone is that clone's own business. Symlinks are not
// followed.
func strayReposUnder(root string) []string {
	var repos []string
	var walk func(dir string)
	walk = func(dir string) {
		if _, owned := identityOwning(dir); owned {
			return
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			// A submodule's or worktree's .git is a file, and either is still
			// a repo, so this matches on the name rather than the type.
			if e.Name() == ".git" {
				repos = append(repos, dir)
				return
			}
		}
		for _, e := range entries {
			if e.IsDir() {
				walk(filepath.Join(dir, e.Name()))
			}
		}
	}
	walk(root)
	return repos
}

// A repo sitting in a workspace root but outside every identity directory
// gets none of the wiring, so it commits as the human -- silently, which is
// the whole problem. Usually the leftovers of a workspace that moved without
// its clones.
func strandedClones() []string {
	roots := basedirs()
	// Plus the directories `rm` left clones in: an identity with a workspace
	// of its own takes the only record of that root with it.
	for _, r := range cfgGetAll("core.strandeddir") {
		roots = append(roots, filepath.FromSlash(r))
	}
	var found []string
	for _, r := range roots {
		if r != "" && isDir(r) {
			found = append(found, strayReposUnder(r)...)
		}
	}
	return sortUnique(found)
}

func strandedRecord(dir string) {
	for _, d := range cfgGetAll("core.strandeddir") {
		if d == gitPath(dir) {
			return
		}
	}
	cfgAdd("core.strandeddir", gitPath(dir))
}

func strandedForget(dir string) {
	var rest []string
	for _, d := range cfgGetAll("core.strandeddir") {
		if d != gitPath(dir) {
			rest = append(rest, d)
		}
	}
	cfgUnsetAll("core.strandeddir")
	for _, d := range rest {
		cfgAdd("core.strandeddir", d)
	}
}

func cmdDoctor(args []string) {
	only := ""
	for len(args) > 0 {
		switch args[0] {
		case "--name":
			if len(args) < 2 {
				die("doctor: --name needs a value")
			}
			only = args[1]
			args = args[2:]
		default:
			die("doctor: unknown flag '" + args[0] + "'")
		}
	}
	requireConfig()
	if only != "" && !identityExists(only) {
		die("identity '" + only + "' not in config (have: " + identityList() + ")")
	}

	say("doctor:")
	check("dependencies present (gh git curl, ssh-keygen if signing, op-cache if used)",
		"brew install the missing one", chkDeps())
	check("helper binaries installed in "+binDir,
		"re-run 'guise setup'", chkBinaries())
	check("helper binaries resolve on PATH to the ones in "+binDir,
		helpersHint(), chkHelpersResolve())
	check("guise resolves on PATH",
		guisePathHint(), chkGuiseOnPath())
	note("guise on PATH is this version ("+version+")",
		guiseVersionHint(), chkGuiseCurrent())
	check("co-author hook installed and executable",
		"re-run 'guise setup'", chkHook())
	check("hook dispatcher installed, one entry per git hook",
		"run 'guise update'", chkDispatcher())
	note("shell hook sourced (lets 'guise use' cd this shell)",
		"re-run 'guise setup', or source "+displayPath(shellHookPath)+" from your shell rc yourself", chkShellHook())
	if haveCodex() {
		note("Codex session hook in place (Codex never reads the workspace's AGENTS.md on its own)",
			"run 'guise update', then trust the hook once with /hooks inside codex", chkCodexHook())
	}
	check("human identity untouched outside "+basedir(""),
		"something overrode global config -- inspect ~/.gitconfig for stray edits", chkHumanUntouched())
	// Walked once, not once per interpolation.
	stranded := ""
	for _, s := range strandedClones() {
		stranded += s + " "
	}
	note("no clones stranded outside an identity directory",
		"these commit as YOU: "+stranded+"-- move them under an identity directory, or point the workspace back with 'guise basedir <path>'",
		stranded == "")
	check("guise-gh refuses to run gh without the identity's token",
		"the installed guise-gh falls back to YOUR gh login when the token fails -- run 'guise update' to reinstall it", chkGhFailsClosed())
	check("default identity is in config",
		"'"+cfgGetOr("core.defaultidentity", "")+"' is no longer an identity -- pick one with 'guise default <name>' (have: "+identityList()+")", chkDefaultExists())
	if inAgentRepo() {
		check("this repository runs its hooks through guise",
			"run 'guise setup-hooks' here, and again after anything that resets the repo's core.hooksPath, such as a dependency install that re-applies its hook setup",
			chkRepoHooksPath())
	}

	mode := ", mode 600"
	if !modesApply() {
		mode = " (NTFS has no modes; the profile's ACL keeps it private)"
	}
	names := listIdentities()
	if len(names) == 0 {
		die("no identities in config -- run 'guise setup'")
	}
	if only != "" {
		names = []string{only}
	}

	for _, name := range names {
		say("")
		if isUser(name) {
			login := cfgGetOr("identity."+name+".login", "")
			say("identity '" + name + "' (account @" + login + "):")
			if keySource(name) == "file" {
				check("token file present, non-empty"+mode,
					"re-run setup with --store file --token-file, or chmod 600 "+cfgGetOr("identity."+name+".tokenfile", ""), chkTokenfile(name))
			} else {
				check("1Password token reachable through "+opReader(name),
					opHint(name), chkOp(name, "token"))
				note("1Password account pinned",
					"re-run 'guise setup --name "+name+"' -- unpinned, a second signed-in 1Password account can take over its reads",
					chkOpPinned(name))
			}
			check("stored token looks like a PAT (github_pat_... / ghp_...)",
				"the stored secret isn't a PAT -- re-run setup with a fresh --token-file", chkToken(name))
			check("token valid and still @"+login,
				"token revoked, expired, or replaced with one for another account -- re-run setup", chkUserReal(name))
			check("token not expiring within 30 days",
				"issue a new PAT and re-run 'guise setup --name "+name+" --token-file <path>'", chkTokenFresh(name))
			check("agent account is not your own account",
				"this identity holds a token for YOUR account -- issue one from the agent account", chkNotHuman(name))
			check("token reaches at least one repository",
				"add @"+login+" as a collaborator and accept the invite as that account, and check the token has the 'repo' scope (docs/troubleshooting.md)", chkReachesRepo(name))
			check("account email well-formed",
				"re-run setup; email must be <userId>+<login>@users.noreply.github.com", chkEmailFormat(name))
			check("token authorized for every SAML SSO org",
				"as the agent account, open the token at github.com/settings/tokens and authorize it under 'Configure SSO'; a fine-grained token needs the org to approve it (docs/troubleshooting.md)", chkSSOAuthorized(name))
			check("no token cache on disk for an account",
				"delete "+filepath.Join(cacheDir, name+".token.json")+" -- guise never writes it for a PAT, so whatever did has read the token: treat it as exposed and issue a new one", chkNoPatCache(name))
		} else {
			say("identity '" + name + "' (" + cfgGetOr("identity."+name+".slug", "") + " on " + cfgGetOr("identity."+name+".owner", "") + "):")
			if keySource(name) == "file" {
				check("key file present, valid"+mode,
					"re-run setup with --store file --pem, or chmod 600 "+cfgGetOr("identity."+name+".keyfile", ""), chkKeyfile(name))
			} else {
				check("1Password key reachable through "+opReader(name),
					opHint(name), chkOp(name, "private_key"))
				note("1Password account pinned",
					"re-run 'guise setup --name "+name+"' -- unpinned, a second signed-in 1Password account can take over its reads",
					chkOpPinned(name))
			}
			check("token mints (ghs_...)",
				"wrong app id / installation id / PEM -- re-run setup with a fresh --pem", chkToken(name))
			check("token cache returns identical token",
				"cache dir "+cacheDir+" unwritable, or expiry math broken", chkCache(name))
			check("bot email well-formed",
				"re-run setup; email must be <botUserId>+<slug>[bot]@users.noreply.github.com", chkEmailFormat(name))
			check("bot user id matches GitHub",
				"slug or bot user id stale -- re-run setup to rediscover", chkBotReal(name))
			check("app id != bot user id (the classic mixup)",
				"config has the app id in the email -- re-run setup", chkIdsDiffer(name))
			check("installation reaches at least one repository",
				"the app is installed on no repos -- open its installation settings and pick some under 'Only select repositories'", chkReachesRepo(name))
		}
		check("includeIf resolves identity inside "+identityDir(name)+"/",
			"check the include block in ~/.gitconfig and "+ownedGitconfig, chkIncludeIf(name))
		check("agent scope runs hooks through the dispatcher",
			"run 'guise update' to re-render the conf; if it still fails, ~/.gitconfig sets core.hooksPath below the guise block, which wins -- move the guise block to the end",
			chkHooksPath(name))
		if signingEnabled(name) {
			login := cfgGetOr("identity."+name+".login", "")
			check("signing key present"+mode,
				"regenerate it with 'guise setup --sign --name "+name+"'", chkSigningKey(name))
			check("signing key registered on @"+login,
				"as the agent account, add "+signingKey(name)+".pub at github.com/settings/ssh/new with Key type: Signing Key",
				chkSigningRegistered(name))
			check("agent scope signs with ssh-keygen, not an inherited signer",
				"run 'guise update' to re-render the conf; if it still fails, ~/.gitconfig sets gpg.ssh.program below the guise block, which wins -- move the guise block to the end",
				chkSigningProgram(name))
			check("agent scope signs with the identity's own key file",
				"run 'guise update'; if it still fails, ~/.gitconfig sets user.signingkey below the guise block, which wins -- move the guise block to the end",
				chkSigningkeyPath(name))
			check("commits sign and verify in agent scope",
				"fix any signing check above first; otherwise try a commit inside "+identityDir(name)+"/ and read git's error", chkSigns(name))
		} else {
			check("commit signing off in agent scope",
				"rendered conf should set commit.gpgsign=false -- re-run setup", chkGpgsign(name))
		}
		check("credential helper wins (x-access-token)",
			"inherited osxkeychain not cleared -- rendered conf needs the empty 'helper =' line", chkCredential(name))
	}

	say("")
	if doctorFailures > 0 {
		say(fmt.Sprintf("doctor: %d check(s) failed", doctorFailures))
		os.Exit(1)
	}
	say("doctor: all checks passed")
}

// The installed shims are sh scripts, which Windows cannot run on its own.
func shimCommand(path string, args ...string) *exec.Cmd {
	if runtime.GOOS == "windows" {
		return exec.Command("sh", append([]string{path}, args...)...)
	}
	return exec.Command(path, args...)
}

func runShimOutput(path string, args ...string) (string, error) {
	cmd := shimCommand(path, args...)
	cmd.Stdin = nil
	out, err := cmd.Output()
	return chomp(string(out)), err
}
