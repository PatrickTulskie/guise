## 0.7.3

### Added

* Codex gets the workspace `AGENTS.md`: when `~/.codex` exists, `setup` and `update` add a `SessionStart` hook to `~/.codex/hooks.json` that hands it over, leaving your other hooks alone; trust it once with `/hooks` in Codex, and `doctor` says whether it's in place (#70)
* `guise context` prints the workspace `AGENTS.md` for the directory a session hook hands it on stdin, or the current one, so any harness's hook can use it (#70)

## 0.7.2

### Changed

* `update` leaves a shell hook you deleted from your shell rc deleted; `setup` still adds it (#69)

### Fixed

* A `$HOME` with a `#` or `;` in it no longer truncates the hooks path, signing key or allowed signers file git reads from an identity's config, which failed setup and every signed commit (#65)
* `doctor --name` refuses an identity that isn't in config, instead of failing every check with hints that point at the wrong fix (#67)
* `setup --login` reuses the stored token of the account it names, not the default identity's (#68)

## 0.7.1

### Fixed

* A `$HOME` with a space or an apostrophe in it no longer breaks the credential helper, or every git command in scope with it (#59)
* `rename` moves an identity's files before its config, refuses one whose directory holds another identity, and puts everything back when a step fails (#60)
* `basedir` and `setup --base-dir` clean the path and refuse a filesystem root, and `basedir` puts back a move that fails partway (#60)
* `doctor` reports a stray clone at any depth under the workspace, not just three levels down (#61)
* On Windows, a key or token saved with CRLF line endings still parses (#62)
* On Windows, `doctor` finds the installed helpers on `PATH`, and `use` opens its shell with Git Bash's own `$PWD` (#62)

## 0.7.0

### Added

* Every GitHub release ships a build per platform -- macOS, Linux and Windows, amd64 and arm64 -- with a checksum file (#48)

### Changed

* guise is one Go binary instead of a bash script, so it behaves the same on macOS, Linux, Git Bash and WSL; `make install` builds it, and the helpers and hooks it installs are `sh` shims that call back into it (#47)
* `jq` and `openssl` are no longer needed; building from source needs Go 1.24 (#47)

### Fixed

* `guise-credential` resolves the token before answering git, so a failed read fails the push instead of handing git an empty password (#47)

## 0.6.1

### Fixed

* On Git Bash, `doctor`'s hint for a shadowed helper names its directories as `~/...` instead of `C:/Users/...` (#44)

## 0.6.0

### Added

* `guise triage`, so a problem `doctor` can't explain gets an agent briefed on the source and the machine (#33)
* `guise cp`, so a second workspace for the same account reuses its secret and signing key instead of a second setup (#39)
* `guise setup-hooks`, so a repo that pins its own `core.hooksPath` keeps both its hooks and the co-author trailer (#40)
* Windows support, in Git Bash and WSL (#38)
* `doctor` catches a PAT no SAML org has authorized, a fail-open `guise-gh`, a dangling default identity and a cached PAT (#35)
* `doctor` fails when `guise-gh` doesn't resolve to the installed helper, and `setup` names the `PATH` line to add when `~/.local/bin` is missing (#37)

### Changed

* `--store op` and `op-cache` need 1Password CLI 2.30 or newer (#36)

### Fixed

* Agent commits run a repo's own `.git/hooks` alongside guise's instead of skipping them (#40)
* The secret stays out of `op`'s and `curl`'s argv, where `ps` showed it to the agent (#36)
* `setup` reads a reused secret through its owner's 1Password account, keeps an explicit `--op-account` through a wizard review, and stores the secret again when the same item path is in another account (#41)
* `rm` records a removed identity's directory before cleanup, and a flag-driven `rm --code` warns before deleting unpushed work (#34)

## 0.5.0

### Added

* `guise rm`, so dropping one identity doesn't mean uninstalling all of them (#27)
* `setup --op-item`, and a wizard option, to point an identity at a secret already in 1Password (#30)

### Fixed

* `setup` pins the 1Password account, so signing in to a second account can't break an identity's reads (#29)
* A bare `setup` re-run keeps an identity's existing 1Password item instead of recreating it in `Private` (#30)

## 0.4.0

### Added

* `guise list`, one row per identity with the account it commits as, its store and workspace (#25)
* `guise warm-cache`, so the first op-cache read of a login session is yours, not an unattended agent's (#25)

### Fixed

* A `--sign` identity names `ssh-keygen` as its signer, so a global `op-ssh-sign` can't break agent commits or echo the signing key into a transcript (#24)

## 0.3.0

### Added

* Experimental `--store op-cache`, so a 1Password-backed identity keeps working after the vault locks (#20)

### Fixed

* `guise-gh` stops when the identity's token can't be read, instead of falling back to the human's `gh` login (#19)

## 0.2.1

### Added

* Re-running the wizard for an existing identity starts from its current values (#17)

### Fixed

* An identity's secret file is shredded once it moves into 1Password (#17)
* A re-run creates the identity's directory where its basedir points, instead of duplicating a moved workspace (#17)

## 0.2.0

### Breaking Changes

* **`setup` defaults to a separate GitHub account** - pass `--owner`/`--app-id`/`--pem` or `--kind app` for an app bot (#11)
* **New identities store their secret in a file** - pass `--store op` for 1Password (#11)

### Added

* Friendlier setup wizard: arrow-key menus, a signing-key walkthrough, and one last look before anything is written (#12)
* Re-running `setup` for an app identity by name, or bare for the default, reuses its saved owner and App ID (#11)
* A container to run `setup` against without touching your machine (#10)

### Changed

* Docs and `doctor` recommend a classic PAT with the `repo` scope (#11)
* CI runs on PRs against any base branch (#14)

## 0.1.0

Initial release.

* Guided setup wizard (#6)
* `guise basedir` moves the workspace after setup, and varies per identity (#5)
* `guise version`, `--version` and `-v` (#7)
* MIT license (#8)
* Renamed from `agent-id` to `guise` (#1)
