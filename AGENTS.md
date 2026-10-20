# Working in guise

`bin/guise` provisions a dedicated GitHub identity for coding harnesses, so
agent commits land as the agent instead of impersonating the human. One bash
script, one shell test harness, and docs someone else can self-serve from.

Applies to Claude Code, Cursor, and any other AI coding tool; `CLAUDE.md` only
imports this file.

Rules from `~/agentic-code/AGENTS.md` (use `guise-gh`, no hand-written
`Co-authored-by`, never touch git config or remotes) stack on top of this file
and still apply. What follows is specific to this repo.

## Never test setup, uninstall, rename, or rm against your real machine

`setup` rewrites `~/.gitconfig`, writes `~/.config/guise/`, and installs into
`~/.local/bin`. `uninstall` tears out the wiring for **every** identity at once
and takes `~/.config/guise` with it — and it will happily do that to a real
identity that is currently in use.

Exercise the tool through the test harness, which sandboxes `$HOME`, or through
the container, which sandboxes the whole machine:

```bash
docker compose run --rm shell     # a $HOME, GitHub and 1Password you can wreck
```

If you genuinely need a manual run on the host, point it somewhere disposable
first:

```bash
HOME=$(mktemp -d) PATH="tests/stubs:$PATH" bin/guise setup --help
```

Never run a bare `bin/guise setup`, `uninstall`, `rename`, or `rm` to "see what
happens". Ask instead.

That rule is about developing on the tool, not about using it. When the human
asks you to set up *their* machine, do it — that is onboarding, and it is the
entire reason this repo exists. Confirm the identity flags with them first
(`--kind`, `--login` / `--owner`, `--vault`) and never invent a value they did
not give you; `setup` prompts for the credential itself, so let it. Check that
you are on the machine they mean, too — `setup` writes to the `$HOME` of
whatever host you happen to be running on, so from a cloud or container session
you would file their PAT somewhere ephemeral and useless.

Pass the flags; don't reach for the wizard. A bare `setup` asks for its answers
only when stdin is a terminal, which yours is not, so it will refuse on a
missing flag the way it always has — and `--wizard` in a tool call would block
on the first prompt. The guided path is there for the human to run themselves,
and offering them that instead is a fine answer when the flags aren't settled.

`use` is harmless but a bare `guise use` is not for you: with no shell hook
loaded it replaces itself with an interactive shell, so the tool call never
returns. `guise use <name> --emit-shell` only prints the `cd` and is safe.
`guise triage --harness <name>` likewise execs an interactive harness; without
a terminal a bare `triage` only prints its prompt, which is safe.

`uninstall`, `rename` and `rm` stay off the table unless the human asks for that
exact operation and you have read back what it does first. None of them will
stop you: `rename` never confirms, and `uninstall` prompts only on a terminal —
with no TTY, which is your normal case, it skips the prompt. `rm` with no flags
refuses without a TTY, but every flag is an answer, and `--code` or `--force`
deletes the human's clones with no further question. Never pick those flags
yourself.

## Tests

```bash
bash tests/run.sh                 # ~2min, no network
docker compose run --rm tests     # the same suite, on Linux
```

Green is the merge gate; CI runs exactly this on every PR, on macOS, on
Linux, and on Windows inside WSL: macOS is the bash 3.2 and BSD floor
described below, Linux is the GNU tooling cloud-hosted agents run on, and WSL
is Linux with the checkout on the Windows disk. Git Bash, the MSYS environment
described further down, takes 25 minutes a run, so it is a weekly workflow
and a button (Actions → Windows → Run workflow): press it before merging a
change to path handling, the credential plumbing, or the harness. The harness gives each scenario a fresh
sandbox: `$HOME` under `mktemp -d`, `$PATH` prefixed with `tests/stubs`, and
real git/openssl/jq.

The stubs stand in for the outside world, all driven by environment variables
rather than recorded fixtures:

| Stub | Stands in for | Driven by |
|---|---|---|
| `tests/stubs/op` | 1Password CLI, backed by files under `$OP_FAKE_DIR/<vault>/<item>/<field>` (a field's type under `<item>/.type/<field>`); `item get --format json` conceals a value unless `--reveal` asks for it, and `item create`/`item edit` take a JSON template on stdin | `OP_FAKE_ACCOUNT` (the account that tree belongs to; any other account's is under `$OP_FAKE_DIR/<account>/`, and one with no such directory holds nothing), `OP_FAKE_DEFAULT` (the account op falls back to with no `--account`), `OP_FAKE_FORBID` (assert op is never called), `OP_FAKE_VERSION` (what `--version` reports; default 2.30.0), `OP_ARGV_LOG` (every call's argv, so a test can prove a secret never passed through it) |
| `tests/stubs/op-cache` | op-cache, with `$OP_CACHE_FAKE_DIR` standing in for the daemon's memory; a miss falls through to the op stub | `OP_CACHE_LOG` (every call, so a test can tell a cached read from a direct one) |
| `tests/stubs/curl` | the GitHub API, matched on URL, every call logged to `$CURL_LOG`; an endpoint that needs auth fails (exit 22) unless its `Authorization` header came through `--config`, and any `Authorization:` in argv fails outright | `FAKE_APP_ID`, `FAKE_SLUG`, `FAKE_OWNER`, `FAKE_BOT_ID`, `FAKE_LOGIN`, `FAKE_USER_ID`, `FAKE_TOKEN_EXPIRES`, `FAKE_REPO_COUNT` |
| `tests/stubs/gh` | `gh api user` only, to answer "is this the human's own account?" | `FAKE_GH_LOGIN` (unset = logged out, which must warn, not block) |
| `tests/stubs/stat` | real `stat` until asked otherwise, then GNU semantics | `FAKE_STAT_GNU` (makes a macOS run exercise the GNU branch of `file_mode`) |

The curl stub serves the account's public signing keys from
`$SIGNING_KEYS_FILE`; tests append to that file to stand in for a human pasting
a key into GitHub's form. Nothing writes signing keys through the API — that is
a browser step, so there is no endpoint to stub.

Extend a stub when you need new API behavior; do not reach for the network, and
do not add a fixture file. Assert on observable artifacts — a file mode, a
config value, what `git config` resolves to inside the scoped directory, a
byte-identical restore — not on "the command exited 0".

## The container

`docker compose run --rm shell` is a Debian box with the working tree bind
mounted at `/work` and `docker/entrypoint.sh` standing the fake world up around
the shell: the stubs ahead of everything on `PATH`, the same `FAKE_*` values the
suite uses, a fresh `~/sandbox/app-key.pem` for the app path, and `guise`
resolving to `bin/guise` off the working tree so an edit on the host takes
effect on the next command. `setup`, `rename`, `rm` and `uninstall` are all fair
game in there — the `$HOME` they rewrite dies with the container.

It reaches nothing real. There is no `gh` and no `op` in the image, and the
stubbed `curl` is the only one on `PATH`, so a run that somehow escapes the fake
world fails rather than touching the human's account.

The image caches; rebuild it with `docker compose build` after changing
`docker/`. Nothing else in the repo needs a rebuild.

## The script is self-contained

`guise-token`, `guise-credential`, `guise-gh`, the commit hook, the hook
dispatcher, the shell hook, and the git config template are **heredocs inside
`bin/guise`** (`write_helper_*`, `write_hook`, `write_dispatcher`,
`write_shell_hook`, `agent_conf_template`, `signing_*_block`). `setup` writes
them into `~/.local/bin` and `~/.config/guise/`.

Editing an installed copy changes nothing that ships. Edit the heredoc.

Because they are only written at install time, a newer script does nothing until
`setup` or `update` runs. `update` is the one to reach for: it rewrites the
helpers, the hook, and every rendered conf from config alone, with no credential
read and no API call, so it works against a locked vault.

## bash 3.2

macOS ships bash 3.2 as `/bin/bash` and that is the floor. Not available:
associative arrays (`declare -A`), `${var^^}` / `${var,,}`, `mapfile` /
`readarray`, `&>>`, negative string indices, `${!prefix@}`.

The script runs under `set -euo pipefail`, which has traps worth knowing:

- `local x=$(cmd)` **swallows** `cmd`'s exit status — `local x; x=$(cmd) || ...`
  keeps it. The existing code is careful about this; stay careful.
- `git config --get` exits 1 on an unset key, so an unguarded `cfg_get` aborts
  the script. Use `|| true`, or a default, when absence is legitimate. This is
  exactly what once made the commit hook abort commits on a machine with no
  global `user.name`.
- `-e` does not fire on a non-final command in an `&&` list, which is why
  `[[ cond ]] && exit 0` is safe in the hook. Don't "fix" those.
- BSD and GNU disagree on `stat` and `date` flags. Put the form that **fails
  cleanly** first: GNU `stat -f` prints filesystem info to stdout before exiting
  non-zero, so a BSD-first fallback silently returns garbage on Linux. `file_mode`
  tries GNU `stat -c` first for that reason.

## Git Bash

Git for Windows is MSYS2 underneath: bash, coreutils and ssh-keygen are MSYS
programs that see POSIX paths, while git, curl, jq and openssl (the one first
on PATH) are native ones that see Windows paths. MSYS rewrites POSIX paths in
a native program's argv on the way in. Nothing else is rewritten, which is
where everything below comes from:

- A path written into a file git reads has to be in Windows form: go through
  `git_path` (a `cygpath -m` where `cygpath` exists, the path as given
  elsewhere) at the write site, as `render_identity_conf` and `display_path`
  do. Don't convert in the templates.
- A path that went into guise's own config through `git config` came back
  rewritten -- `C:/Users/...` -- so `cfg_get` turns it back into the shell's
  spelling through `posix_path`. Read config through `cfg_get`/`cfg_get_all`,
  not `git config` directly, or string comparisons against `$HOME` fail.
- A native program cannot open `/dev/fd/N`, so a process substitution handed
  to curl or jq fails there. curl takes its config on stdin. openssl has no
  stdin option for a key, so `openssl_for_fd` picks the MSYS build Git for
  Windows ships at `/usr/bin/openssl` -- the key stays off disk and off argv
  either way.
- `chmod` is a no-op (the disk is mounted `noacl`) and every file reads 644.
  `mode_600` is satisfied there, and doctor says so in the check's own words.
- There is no `script`, so the suite's pty scenarios print `skip` on Windows.
  `modes_apply`, `expect_mode`, `git_path` and `cfg` in the harness are the
  same accommodations on the asserting side.

## Secrets

The whole point of this tool is credential separation, so:

- **Never put a secret in argv.** `ps` shows arguments to same-user processes,
  and the agent runs as the same user. Feed subprocesses through a
  builtin-driven pipe or process substitution — a config file printed into
  `curl --config -`, `openssl dgst -sha256 -sign <(read_key) -binary`, a JSON
  template piped into `op item edit` — never `-H "Authorization: ..."`, an
  `op` assignment statement, or `jq --arg`. Prefer stdin where the program
  takes it: a native Windows program cannot open the `/dev/fd` path a process
  substitution hands it (see Git Bash below).
- Secrets live in 1Password, or on disk at mode 600 under
  `~/.config/guise/keys/`. Never under the agent workspace: agents roam there
  and can commit what they read.
- The one exception to "1Password by default" is a `--sign` identity's SSH
  signing key, which is generated locally and stays local. It grants nothing and
  costs one command to replace — delete it, then re-run setup, which reuses an
  existing key and only generates one when none is there. Syncing it would just
  widen where it can leak from. Same directory and same mode as everything else.
  The signing path touches no credential at all — keep it that way; the one
  GitHub call is an unauthenticated read of the account's public key list.
- Shred a source file once its secret is stored somewhere durable, and only
  after.
- `uninstall` removes the wiring but deliberately **leaves stored secrets in
  place**, the same way it leaves 1Password items and clones alone. Don't
  "improve" it into shredding them.
- No token ever reaches stdout, a log, or a doc example. A snippet that pipes
  `git credential fill` must filter the password out; readers paste these.

## Docs

`README.md` is the setup path, `docs/troubleshooting.md` is keyed to real
failure modes. Every `doctor` check prints a remediation hint — a new check
needs one too. When behavior changes, the docs change in the same commit; they
are the reason this tool can be handed to someone else.

## Commits and PRs

One line, imperative, saying why rather than what. No multi-line bodies, and no
trailers you write yourself — a hook credits the human and clears the
`Co-authored-by` a harness stamps for itself, including one you added. A
co-author naming anyone else is that person's only credit: leave it alone.

Stage the files you actually changed. Never `git add .` or `git add -A`: in a
repo whose whole subject is credential handling, a blind stage is how a stray
key, token, or sandbox leftover gets committed.

One commit per logical change. Keep PR descriptions short — assume a reader with
no time — and name the model and harness at the end.

## Layout

```text
bin/guise                the entire tool: subcommands, checks, embedded helpers
tests/run.sh             the whole suite, in a sandboxed $HOME
tests/stubs/{op,curl,gh} the outside world
docs/troubleshooting.md  keyed to real failure modes
compose.yaml, docker/    a disposable machine to run the tool against by hand
.github/workflows/       CI: the suite, on macOS, Linux and WSL on every PR; Git Bash weekly
```
