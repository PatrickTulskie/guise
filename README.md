# agent-id

Gives your coding agents (Claude Code, Cursor) their own GitHub identity. Agent
commits land as `your-app[bot]` with you as co-author, instead of impersonating
you. Everything is scoped to one directory — by default `~/agentic-code/` — and
your own git identity is never touched.

## One-time GitHub setup (two browser steps)

There's no API for these; everything after them is automated.

**1. Create the app** — Settings → Developer settings → GitHub Apps →
New GitHub App (on your personal account):

- Name: `<yourname>-agent`, e.g. `patricktulskie-agent` (globally unique)
- Webhook: **uncheck** Active
- Where can it be installed: **Any account** — this is what lets other people
  and orgs install your agent on their repos, so it can contribute to open
  source projects where permitted
- Repository permissions: Contents **R/W**, Pull requests **R/W**, Issues
  **R/W**, Checks **Read**, Workflows **no access**
- After creating: **Generate a private key** (downloads a `.pem` — keep the
  path handy), and note the **App ID** at the top of the page

**2. Install it** — App settings → Install App → your account. Pick **All
repositories** or select the ones the agent should work in. Anyone else who
wants the agent on their repos installs it the same way from the app's public
page (`github.com/apps/<yourname>-agent`).

If a repo requires signed commits (a ruleset or branch protection), add the
app to the ruleset's bypass list (Settings → Rules → Rulesets → Bypass list →
Apps → mode Always), or the first push will be rejected.

## Setup

```bash
./bin/agent-id setup --owner patricktulskie --app-id 12345 --pem ~/Downloads/your-app.pem
```

What happens: the App's metadata (slug, installation ID, bot user ID) is
discovered from the API, credentials go into 1Password, the PEM is shredded,
helper binaries land in `~/.local/bin`, and a directory-scoped git identity is
wired up for `~/agentic-code/default/`. It finishes by running `doctor`, which
verifies the whole chain. Safe to re-run any time.

Requires: `op` (1Password CLI, signed in), `gh`, `jq`, `openssl`, `git`.

## Daily use

```bash
agent-id clone patricktulskie/some-repo   # clones into ~/agentic-code/default/
cd ~/agentic-code/default/some-repo
# ... let the agent work; commits are authored by the bot, co-authored by you
agent-gh pr create --fill                 # opens the PR as the bot
```

The only convention that matters: **agent clones live under `~/agentic-code/`,
your own clones live anywhere else.** Inside that directory every git operation
— from Claude Code, Cursor, or a plain terminal — uses the bot identity with no
harness-specific configuration. Tell each harness one thing: use `agent-gh`
instead of `gh` (a line in `CLAUDE.md` / Cursor rules).

## Commands

| Command | What it does |
|---|---|
| `agent-id setup` | provision an identity (idempotent) |
| `agent-id doctor` | verify everything; non-zero exit on any failure |
| `agent-id clone <owner/repo>` | clone where the identity applies |
| `agent-id token` | print an installation token (debugging / harness use) |
| `agent-id uninstall` | remove all wiring; 1Password items and clones are left alone |

## Multiple identities

Each identity (one GitHub App each) gets its own subdirectory:

```bash
agent-id setup --owner patricktulskie --app-id 67890 --pem ~/Downloads/other.pem --name experiments
agent-id clone patricktulskie/some-repo --name experiments   # → ~/agentic-code/experiments/
```

## Contributing to repos the app isn't installed on

An installation token only works on repos where the app is installed. For open
source work that means one of:

- the maintainer installs your agent app on their repo/org (the "Any account"
  setting above makes this possible), or
- you fork, install the app on your own fork, push there as the bot, and open
  the PR from the fork.

## When something's off

Run `agent-id doctor` first — every check prints a remediation hint. Then see
[docs/troubleshooting.md](docs/troubleshooting.md).
