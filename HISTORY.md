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
