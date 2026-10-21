package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

// The prepare-commit-msg hook: credit the human as co-author on every commit
// the agent authors, in place of the one a harness stamps for itself.
// prepare-commit-msg (not commit-msg) so `git commit -m` is covered. The
// trailer survives rebase merge and is parsed natively by GitHub.
func cmdHook(args []string) {
	if len(args) < 1 || args[0] != "prepare-commit-msg" {
		die("_hook: unknown hook")
	}
	hookPrepareCommitMsg(args[1:])
}

var revertLineRe = regexp.MustCompile(`^This reverts commit [0-9a-f]{7,}\.$`)

func hookPrepareCommitMsg(args []string) {
	if len(args) < 1 {
		os.Exit(0)
	}
	msgFile := args[0]
	source := ""
	if len(args) > 1 {
		source = args[1]
	}
	// Skip merges and squashes -- trailers there are noise.
	if source == "merge" || source == "squash" {
		return
	}

	// The identity's own address, which is also what a commit it authored
	// carries. Unset outside a repo, and absence is legitimate.
	selfEmail, _ := git("", "config", "--get", "user.email")

	// A replay is someone else's commit passing through -- cherry-pick,
	// revert, a rebase, or an explicit --author. The identity is only the
	// committer, so the human co-authored nothing, and the message already
	// carries whatever credit the original commit was due.
	if gitDir, ok := git("", "rev-parse", "--git-dir"); ok {
		for _, marker := range []string{"CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"} {
			if exists(filepath.Join(gitDir, marker)) {
				return
			}
		}
	}
	// A clean revert never stops the sequencer, so REVERT_HEAD is gone again
	// by the time the message is prepared -- the marker above only catches a
	// revert that conflicted. What survives either way is the line git
	// generates, which carries no translation, so it reads the same in every
	// locale.
	content, ok := readFile(msgFile)
	if !ok {
		os.Exit(1)
	}
	for _, line := range strings.Split(content, "\n") {
		if revertLineRe.MatchString(line) {
			return
		}
	}
	// Cherry-pick leaves GIT_AUTHOR_EMAIL unset, so this catches --author.
	if ae := os.Getenv("GIT_AUTHOR_EMAIL"); ae != "" && selfEmail != "" && ae != selfEmail {
		return
	}

	coAuthor := os.Getenv("GUISE_CO_AUTHOR")
	if coAuthor == "" && configExists() {
		coAuthor = cfgGetOr("core.coauthor", "")
	}
	if coAuthor == "" {
		name, _ := git("", "config", "--global", "user.name")
		email, _ := git("", "config", "--global", "user.email")
		if name != "" && email != "" {
			coAuthor = name + " <" + email + ">"
		}
	}
	// No one to credit: leave the message alone rather than failing the commit.
	if coAuthor == "" {
		return
	}

	// Harnesses stamp a co-author of their own (Claude, Cursor). The commit is
	// already authored by the agent identity, so that credit is redundant --
	// and interpret-trailers matches on the token alone, so any of them would
	// make it skip the human's. Cleared by address, not by token, because a
	// co-author who is neither a harness nor the identity is the real thing:
	// on a reimplemented contribution the trailer is the only credit its
	// author gets. The human's own goes on the list too, so whatever spelling
	// it arrived in is replaced by the canonical one below.
	humanAddr := coAuthor
	if i := strings.LastIndex(humanAddr, "<"); i >= 0 {
		humanAddr = humanAddr[i+1:]
	}
	humanAddr = strings.TrimSuffix(humanAddr, ">")
	drop := map[string]bool{}
	for _, a := range []string{"noreply@anthropic.com", "cursoragent@cursor.com", selfEmail, humanAddr} {
		if a != "" {
			drop[lower(a)] = true
		}
	}
	var kept []string
	for _, line := range fileLines(content) {
		if strings.HasPrefix(lower(line), "co-authored-by:") {
			addr := line
			if i := strings.Index(addr, "<"); i >= 0 {
				addr = addr[i+1:]
			}
			if i := strings.Index(addr, ">"); i >= 0 {
				addr = addr[:i]
			}
			if drop[lower(addr)] {
				continue
			}
		}
		kept = append(kept, line)
	}
	// Nothing but trailers is not worth losing a message over.
	if len(kept) > 0 {
		writeFile(msgFile, strings.Join(kept, "\n")+"\n", 0o644)
	}

	cmd := exec.Command("git", "interpret-trailers", "--if-exists", "addIfDifferent",
		"--trailer", "Co-authored-by: "+coAuthor, "--in-place", msgFile)
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		os.Exit(exitCode(err))
	}
}

// The dispatcher: run the repository's own hook of this name, then guise's.
// Called from the shim as `_dispatch "$0" "$@"`, so the first argument is
// the dispatcher's own path, which names the hook.
func cmdDispatch(args []string) {
	if len(args) < 1 {
		die("_dispatch: no hook name")
	}
	self := args[0]
	hookArgs := args[1:]
	hook := filepath.Base(self)
	own := filepath.Join(hooksDir, hook)

	// The hooks path `guise setup-hooks` displaced, when the repository pins
	// one of its own; otherwise the common .git/hooks, so a linked worktree
	// finds the hooks of the repository it belongs to. Relative to the top of
	// the working tree, which is where git runs hooks from and how it reads a
	// relative core.hooksPath. `git init` fires reference-transaction before
	// there is a repository to find, and a failure here would abort the init,
	// so no repository means no repository hooks.
	inner, _ := git("", "config", "--type=path", "--get", "guise.innerhookspath")
	if inner == "" {
		if common, ok := git("", "rev-parse", "--git-common-dir"); ok {
			inner = filepath.Join(common, "hooks")
		}
	}
	if inner != "" && !filepath.IsAbs(inner) {
		top, ok := git("", "rev-parse", "--show-toplevel")
		if !ok {
			top = cwd()
		}
		inner = filepath.Join(top, inner)
	}

	// Repository first: a prepare-commit-msg that writes the message wholesale
	// would wipe a trailer added ahead of it. A hooks directory that is this
	// one, however it got there, must not run the dispatcher under itself.
	if inner != "" {
		theirs := filepath.Join(inner, hook)
		if isExecutable(theirs) && !sameFile(theirs, self) {
			if err := runHook(theirs, hookArgs); err != nil {
				os.Exit(exitCode(err))
			}
		}
	}

	// guise's hooks are for the identity's own commits. A clone that left its
	// identity's directory can still point here, and the human's commits in
	// it get nothing added.
	if ident, _ := git("", "config", "--get", "guise.identity"); ident != "" && isExecutable(own) {
		if err := runHook(own, hookArgs); err != nil {
			os.Exit(exitCode(err))
		}
	}
}

// A repository's hook may be anything executable; on Windows a script with
// a shebang needs sh to run it, which git itself would have found.
func runHook(path string, args []string) error {
	cmd := exec.Command(path, args...)
	if runtime.GOOS == "windows" {
		if head, _ := readFile(path); strings.HasPrefix(head, "#!") {
			cmd = exec.Command("sh", append([]string{path}, args...)...)
		}
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}
