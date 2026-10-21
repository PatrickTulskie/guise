# Working in guise

`guise` provisions a dedicated GitHub identity for coding harnesses, so agent
commits land as the agent instead of impersonating the human. One Go binary,
one shell test harness, and docs someone else can self-serve from.

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
make && HOME=$(mktemp -d) PATH="tests/stubs:$PATH" bin/guise setup --help
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

## Building

```bash
make              # bin/guise for this machine
make install      # ...and copy it to ~/.local/bin (BINDIR=... elsewhere)
make vet          # gofmt and go vet, what CI runs before the suite
make dist         # one archive per platform, what a release attaches
```

Go 1.24 or newer, stdlib plus `golang.org/x/term` for the wizard's terminal
handling; nothing else. Keep it that way — a dependency is something every
platform build and every reviewer has to carry.

## Tests

```bash
bash tests/run.sh                 # builds bin/guise, then under a minute, no network
bash tests/run.sh rm cp           # just those cases
JOBS=1 bash tests/run.sh          # one case at a time
docker compose run --rm tests     # the same suite, on Linux
```

Green is the merge gate; CI runs `make vet` and exactly this on every PR, on
macOS, on Linux, and on Windows inside WSL: macOS is the BSD floor, Linux is
the GNU tooling cloud-hosted agents run on, and WSL is Linux with the checkout
on the Windows disk. Git Bash, the MSYS environment described further down,
takes 15 to 25 minutes a run, so it is a weekly workflow and a button (Actions
→ Windows → Run workflow): press it before merging a change to path handling,
the credential plumbing, or the harness.

The suite runs the binary it builds at the start of `run.sh`, at `$GUISE`
(`bin/guise` by default), so the cases always test the source as it stands.
Every file under `tests/cases/` is one scenario, and `run.sh` runs as many of
them at once as there are cores. Each starts with `new_sandbox` from
`tests/lib.sh`: `$HOME` under `mktemp -d`, `$PATH` prefixed with `tests/stubs`,
and real git/openssl/jq. Cases share nothing but the stubs, so a new one gets
its own file and its own sandbox, and never leans on what another case set up.
Within a case, run `setup` or `doctor` once into a file and assert on that
several times, rather than once per assertion. The pty helpers (`in_pty`,
`have_pty`) live in `lib.sh` too.

The stubs stand in for the outside world, all driven by environment variables
rather than recorded fixtures:

| Stub | Stands in for | Driven by |
|---|---|---|
| `tests/stubs/op` | 1Password CLI, backed by files under `$OP_FAKE_DIR/<vault>/<item>/<field>` (a field's type under `<item>/.type/<field>`); `item get --format json` conceals a value unless `--reveal` asks for it, and `item create`/`item edit` take a JSON template on stdin | `OP_FAKE_ACCOUNT` (the account that tree belongs to; any other account's is under `$OP_FAKE_DIR/<account>/`, and one with no such directory holds nothing), `OP_FAKE_DEFAULT` (the account op falls back to with no `--account`), `OP_FAKE_FORBID` (assert op is never called), `OP_FAKE_VERSION` (what `--version` reports; default 2.30.0), `OP_ARGV_LOG` (every call's argv, so a test can prove a secret never passed through it) |
| `tests/stubs/op-cache` | op-cache, with `$OP_CACHE_FAKE_DIR` standing in for the daemon's memory; a miss falls through to the op stub | `OP_CACHE_LOG` (every call, so a test can tell a cached read from a direct one) |
| `tests/stubs/curl` | the GitHub API, matched on URL, every call logged to `$CURL_LOG`; an endpoint that needs auth fails (exit 22) unless its `Authorization` header came through `--config`, and any `Authorization:` in argv fails outright | `FAKE_APP_ID`, `FAKE_SLUG`, `FAKE_OWNER`, `FAKE_BOT_ID`, `FAKE_LOGIN`, `FAKE_USER_ID`, `FAKE_TOKEN_EXPIRES`, `FAKE_REPO_COUNT` |
| `tests/stubs/gh` | `gh api user` only, to answer "is this the human's own account?" | `FAKE_GH_LOGIN` (unset = logged out, which must warn, not block) |
| `tests/stubs/stat` | real `stat` until asked otherwise, then GNU semantics; the binary reads modes itself, so this now only shapes the suite's own `file_mode` | `FAKE_STAT_GNU` |

The curl stub serves the account's public signing keys from
`$SIGNING_KEYS_FILE`; tests append to that file to stand in for a human pasting
a key into GitHub's form. Nothing writes signing keys through the API — that is
a browser step, so there is no endpoint to stub.

GitHub is reached through `curl` on purpose, not `net/http`: the stub is what
lets the suite run without a network, and it is also what proves no bearer
ever reaches argv. Extend a stub when you need new API behavior; do not reach
for the network, and do not add a fixture file. Assert on observable
artifacts — a file mode, a config value, what `git config` resolves to inside
the scoped directory, a byte-identical restore — not on "the command exited 0".

## The container

`docker compose run --rm shell` is a Debian box with Go, the working tree bind
mounted at `/work`, and `docker/entrypoint.sh` standing the fake world up
around the shell: the stubs ahead of everything on `PATH`, the same `FAKE_*`
values the suite uses, a fresh `~/sandbox/app-key.pem` for the app path, and
`guise` built from the working tree into the container's own `$HOME` as the
shell starts. `guise-rebuild` picks up an edit made on the host. `setup`,
`rename`, `rm` and `uninstall` are all fair game in there — the `$HOME` they
rewrite dies with the container.

It reaches nothing real. There is no `gh` and no `op` in the image, and the
stubbed `curl` is the only one on `PATH`, so a run that somehow escapes the fake
world fails rather than touching the human's account.

The image caches modules and a first build; rebuild it with
`docker compose build` after changing `docker/` or `go.mod`. Nothing else in
the repo needs a rebuild.

## One binary

`cmd/guise/` is the whole tool, one `package main` split by concern:
`setup.go`, `wizard.go`, `doctor.go`, `commands.go`, `triage.go`, the helpers
in `helpers.go` and the commit hook and dispatcher in `hook.go`. What `setup`
writes to disk is in `assets.go`: `guise-token`, `guise-credential`, `guise-gh`,
the commit hook and the one dispatcher every git hook name runs are **`sh`
shims that call back into the installed binary** (`guise token`, `_credential`,
`_gh`, `_hook`, `_dispatch`), and the shell hook and git config template are
string constants beside them. `setup` writes them into `~/.local/bin` and
`~/.config/guise/`.

Editing an installed shim changes nothing that ships. Edit the Go.

Because they are only written at install time, a newer binary does nothing
until `setup` or `update` runs. `update` is the one to reach for: it copies the
running binary into `~/.local/bin` and rewrites the shims, the hook, and every
rendered conf from config alone, with no credential read and no API call, so it
works against a locked vault.

guise's own config stays a git config file, read and written through `git
config -f` (`config.go`): the suite edits it with the same command, and a
hand edit has to keep working. Reads come from one `--list` per invocation;
every write drops that cache. Go through `cfgGet`/`cfgSet`, never `git
config` by hand.

## Platforms

The binary is built for macOS, Linux and Windows, and the shims it writes are
POSIX `sh` -- the one shell every one of those has once git is installed. Keep
the Go to the standard library's portable surface: `path/filepath`, never
string-built paths; `os.Rename` rather than `mv`; `runtime.GOOS == "windows"`
where a behavior genuinely differs. Things that differ:

- On Windows `guise` is a native program that sees Windows paths, while the
  suite, the shims and git's hooks run under Git Bash and see POSIX ones.
  Paths written where git reads them go through `gitPath` (forward slashes);
  paths read back out of config go through `cfgPath`. The shims name the
  binary by its Windows path, which Git Bash's `sh` follows.
- `chmod` is a no-op on NTFS and every file reads 644. `modesApply` is false
  there, `mode600` is satisfied, and doctor says so in the check's own words.
- A shim is a script, and Windows cannot exec one directly: anything that
  runs an installed helper goes through `shimCommand`, which prefixes `sh`
  there.
- There is no `exec(2)`: `execReplace` runs the child and exits with its
  status, so `use` and `triage` behave the same from the outside.

## Secrets

The whole point of this tool is credential separation, so:

- **Never put a secret in argv.** `ps` shows arguments to same-user processes,
  and the agent runs as the same user. Feed subprocesses on stdin — a config
  file printed into `curl --config -`, a JSON template piped into `op item
  edit` — never `-H "Authorization: ..."` or an `op` assignment statement. The
  App JWT is signed in-process (`crypto/rsa`), so the key never leaves memory.
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
  after. `shredFile` overwrites before it unlinks.
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

## Releases

`const version` in `cmd/guise/main.go` is the version; bump it in its own
commit. Publishing a GitHub release whose tag is `v<version>` runs
`.github/workflows/release.yml`, which refuses a tag that doesn't match the
source, runs `make dist`, and attaches one archive per platform plus a
checksum file to the release.

## Layout

```text
cmd/guise/               the entire tool: subcommands, checks, embedded shims and templates
Makefile                 build, install, vet, test, dist
tests/run.sh             builds the binary, runs the cases in parallel and sums them up
tests/lib.sh             the sandbox, the assertions, and the pty helpers
tests/cases/             one scenario per file, each in a sandboxed $HOME
tests/stubs/{op,curl,gh} the outside world
docs/troubleshooting.md  keyed to real failure modes
compose.yaml, docker/    a disposable machine to run the tool against by hand
.github/workflows/       CI: the suite, on macOS, Linux and WSL on every PR; Git Bash weekly; builds on release
```
