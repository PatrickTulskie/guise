// guise provisions a dedicated GitHub identity for coding harnesses.
//
// An identity is either a GitHub App installation (a bot) or a separate
// GitHub account holding a PAT. One binary is the whole tool: the helpers,
// the commit hook and the hook dispatcher it installs are shims that call
// back into it.
package main

import (
	"fmt"
	"os"
)

const version = "0.6.1"

func main() {
	initEnv()
	args := os.Args[1:]
	cmd := ""
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "setup":
		cmdSetup(args)
	case "doctor":
		cmdDoctor(args)
	case "triage":
		cmdTriage(args)
	case "uninstall":
		cmdUninstall(args)
	case "clone":
		cmdClone(args)
	case "use":
		cmdUse(args)
	case "update":
		cmdUpdate(args)
	case "setup-hooks":
		cmdSetupHooks(args)
	case "token":
		cmdToken(args)
	case "default":
		cmdDefault(args)
	case "rename":
		cmdRename(args)
	case "cp":
		cmdCp(args)
	case "rm":
		cmdRm(args)
	case "basedir":
		cmdBasedir(args)
	case "which":
		cmdWhich(args)
	case "list":
		cmdList(args)
	case "warm-cache":
		cmdWarmCache(args)
	case "version", "--version", "-v":
		say("guise " + version)
	case "help", "--help", "-h", "":
		fmt.Print(usage())
	// What the installed shims call back into: guise-credential, guise-gh,
	// the commit hook, and the one dispatcher every git hook name runs.
	case "_credential":
		cmdCredential(args)
	case "_gh":
		cmdGh(args)
	case "_hook":
		cmdHook(args)
	case "_dispatch":
		cmdDispatch(args)
	default:
		fmt.Fprint(os.Stderr, usage())
		die("unknown command '" + cmd + "'")
	}
}

func say(s string) { fmt.Fprintln(os.Stdout, s) }

func warn(s string) { fmt.Fprintln(os.Stderr, "guise: "+s) }

func die(s string) {
	fmt.Fprintln(os.Stderr, "guise: error: "+s)
	os.Exit(1)
}

func usage() string {
	return "guise " + version + ` -- a dedicated GitHub identity for coding harnesses

usage: guise <command> [flags]

  setup      provision an identity (idempotent; safe to re-run)
             Separate GitHub account (default):
               [--login <account>] [--token-file <path>]
               the token file is shredded after storing; with neither flag
               setup reuses a stored token or prompts (never via argv)
               [--sign | --no-sign]  SSH-sign this identity's commits with a
                                     key of its own (app identities can't)
             GitHub App bot (implied by any of its flags, or --kind app):
               --owner <account> --app-id <id> [--pem <path>]
               --pem is only needed the first time per app; later identities
               of the same app reuse the stored key
             common:
               [--name <identity>]  default: the app slug / account login
               [--default]          make this the default identity
               [--store <file|op|op-cache>]
                                    file: secret on disk, mode 600 (default
                                          for a new identity)
                                    op: secret in 1Password, read on
                                        demand; a locked vault blocks
                                        the agent
                                    op-cache (experimental): secret in
                                        1Password, read through op-cache,
                                        which keeps it in memory for the
                                        rest of the login session; needs
                                        op-cache on PATH
                                    re-running setup keeps the store the
                                    identity already uses; a different one
                                    moves the secret
               [--vault <1password vault>] [--op-account <1password account>]
                                    default account: the one op answers
                                    for now, pinned so a second sign-in
                                    can't take over its reads
               [--op-item op://<vault>/<item>]
                                    use the secret already in this item
                                    (its token field, or private_key for
                                    an app) instead of writing one; a new
                                    --token-file or --pem goes into it
               [--coauthor "Name <email>"] [--base-dir <dir>]
               [--wizard]   ask for the answers instead of taking flags;
                            this is what a bare "guise setup" does on a
                            terminal. [--no-wizard] to insist on flags.
  doctor     verify the whole chain; non-zero exit on any failure
             [--name <identity>]
  triage     start a session in your coding harness (claude, codex,
             cursor-agent, opencode, pi) to work out what's wrong, with a
             prompt that points it at the source, doctor, and your machine
             [--harness <name>]  skip the menu
             [--print]           print the prompt instead; also what happens
                                 with no terminal or no harness found
  uninstall  remove all wiring; leaves keys + clones alone  [-y]
  clone      clone a repo into the agent directory so the identity applies
             <owner/repo | url> [--name <identity>]
             without --name: the identity owning the current directory,
             otherwise the default
  use        go to an identity's directory  [<name>]
             without <name>: the default identity; cds the current shell once
             the shell hook is loaded, otherwise opens a subshell
  update     reinstall the helpers, hook, and rendered confs from this copy
             of guise; no credential read, no network, config untouched
  setup-hooks
             inside an agent clone that pins core.hooksPath of its own: run
             those hooks ahead of guise's instead of in place of it; re-run
             after the repo's tooling resets that path
  token      print the identity's token  [identity]
  default    show the identity used when none is named, or set it  [<name>]
  rename     rename an identity, its directory, and its key files
             <old> <new>
  cp         a second workspace committing as the same account, without a
             second setup: the secret file and signing key are copied, a
             1Password item is shared  <identity> <new-name>
  rm         remove one identity; a bare "guise rm" on a terminal asks what
             should go with it, and without a terminal it needs a flag
             [<identity>] [--keep | --code --secret --signing-key | --force]
             --keep: the wiring only    --code: its directory and clones
             --secret: its key or token file    --signing-key: its signing key
             --force: all of those; a 1Password item is yours and always stays
  basedir    show or move the workspace directory, taking the clones with it
             [<path>] [--name <identity>] [--unset]
             without <path>: print it; --name: just that identity's, which
             overrides the shared one; --unset: drop an override
  which      print the identity owning the current directory
  list       print every identity, its account, store, and workspace
  warm-cache read every op-cache-backed secret once, so the first agent of
             the session doesn't hit the 1Password prompt  [--name <identity>]
  version    print the version of this copy of guise
`
}
