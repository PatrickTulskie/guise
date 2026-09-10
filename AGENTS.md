# Working in agent-identity-framework

`bin/agent-id` provisions a dedicated GitHub identity for coding harnesses, so
agent commits land as the agent instead of impersonating the human. One bash
script, one shell test harness, and docs someone else can self-serve from.

Applies to Claude Code, Cursor, and any other AI coding tool; `CLAUDE.md` only
imports this file.

Rules from `~/agentic-code/AGENTS.md` (use `agent-gh`, no hand-written
`Co-authored-by`, never touch git config or remotes) stack on top of this file
and still apply. What follows is specific to this repo.

## Never test setup, uninstall, or rename against your real machine

`setup` rewrites `~/.gitconfig`, writes `~/.config/agent-id/`, and installs into
`~/.local/bin`. `uninstall` tears out the wiring for **every** identity at once
and takes `~/.config/agent-id` with it — and it will happily do that to a real
identity that is currently in use.

Exercise the tool through the test harness, which sandboxes `$HOME`. If you
genuinely need a manual run, point it somewhere disposable first:

```bash
HOME=$(mktemp -d) PATH="tests/stubs:$PATH" bin/agent-id setup --help
```

Never run a bare `bin/agent-id setup`, `uninstall`, or `rename` to "see what
happens". Ask instead.

That rule is about developing on the tool, not about using it. When the human
asks you to set up *their* machine, do it — that is onboarding, and it is the
entire reason this repo exists. Confirm the identity flags with them first
(`--kind`, `--login` / `--owner`, `--vault`) and never invent a value they did
not give you; `setup` prompts for the credential itself, so let it. Check that
you are on the machine they mean, too — `setup` writes to the `$HOME` of
whatever host you happen to be running on, so from a cloud or container session
you would file their PAT somewhere ephemeral and useless.

`use` is harmless but a bare `agent-id use` is not for you: with no shell hook
loaded it replaces itself with an interactive shell, so the tool call never
returns. `agent-id use <name> --emit-shell` only prints the `cd` and is safe.

`uninstall` and `rename` stay off the table unless the human asks for that exact
operation and you have read back what it does first. Neither will stop you:
`rename` never confirms, and `uninstall` prompts only on a terminal — with no
TTY, which is your normal case, it skips the prompt.

## Tests

```bash
bash tests/run.sh      # ~2min, no network
```

Green is the merge gate; CI runs exactly this on every PR (macOS only — see
below). The harness gives each scenario a fresh sandbox: `$HOME` under
`mktemp -d`, `$PATH` prefixed with `tests/stubs`, and real git/openssl/jq.

Three stubs stand in for the outside world, all driven by environment variables
rather than recorded fixtures:

| Stub | Stands in for | Driven by |
|---|---|---|
| `tests/stubs/op` | 1Password CLI, backed by files under `$OP_FAKE_DIR/<vault>/<item>/<field>` | `OP_FAKE_ACCOUNT`, `OP_FAKE_FORBID` (assert op is never called) |
| `tests/stubs/curl` | the GitHub API, matched on URL, every call logged to `$CURL_LOG` | `FAKE_APP_ID`, `FAKE_SLUG`, `FAKE_OWNER`, `FAKE_BOT_ID`, `FAKE_LOGIN`, `FAKE_USER_ID`, `FAKE_TOKEN_EXPIRES`, `FAKE_REPO_COUNT` |
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

## The script is self-contained

`agent-id-token`, `agent-id-credential`, `agent-gh`, the commit hook, the shell
hook, and the git config template are **heredocs inside `bin/agent-id`**
(`write_helper_*`, `write_hook`, `write_shell_hook`, `agent_conf_template`,
`signing_*_block`). `setup` writes them into `~/.local/bin` and
`~/.config/agent-id/`.

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

## Secrets

The whole point of this tool is credential separation, so:

- **Never put a secret in argv.** `ps` shows arguments to same-user processes,
  and the agent runs as the same user. Feed subprocesses through a
  builtin-driven process substitution — `curl --config <(printf ...)`,
  `openssl dgst -sha256 -sign <(read_key) -binary` — never
  `-H "Authorization: ..."`.
- Secrets live in 1Password, or on disk at mode 600 under
  `~/.config/agent-id/keys/`. Never under the agent workspace: agents roam there
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
trailers you write yourself — a hook makes the human the sole co-author, and
clears every other `Co-authored-by`, including one you added.

Stage the files you actually changed. Never `git add .` or `git add -A`: in a
repo whose whole subject is credential handling, a blind stage is how a stray
key, token, or sandbox leftover gets committed.

One commit per logical change. Keep PR descriptions short — assume a reader with
no time — and name the model and harness at the end.

## Layout

```text
bin/agent-id             the entire tool: subcommands, checks, embedded helpers
tests/run.sh             the whole suite, in a sandboxed $HOME
tests/stubs/{op,curl,gh} the outside world
docs/troubleshooting.md  keyed to real failure modes
.github/workflows/       CI: the suite, on macOS, on every PR
```
