# guise

A dedicated GitHub identity for coding harnesses.

## For Humans

When you develop with agents, it is worth giving the agent a limited subset of
your permissions and making it clear that the agent wrote the code and you are
reviewing and pushing it. An agent identity lets you move quicker while still
leaving an honest trail. This framework sets that up alongside your regular
git configuration, without disturbing it.

If you're a human, you don't have to read the rest of this README. Clone the
repo and run setup with no arguments — it asks for what it needs, walks you
through the GitHub-side steps that have to happen in a browser, and waits:

```bash
./bin/guise setup
```

Or hand the repo to your harness of choice and tell it to set up your machine.
Either way you need the GitHub side first — an account or app for the agent,
and a credential issued from it; that's the only part nobody can automate for
you.

Know the flags already? Pass them and the questions don't happen:

```bash
./bin/guise setup --kind user --login your-agent-account
```

`setup` prompts for the PAT — there is deliberately no `--token` flag, since
argv is visible in `ps`. Add `--sign` if the repos you work in require signed
commits; see [Signed commits](#signed-commits).

### Guided or flag-driven

A bare `guise setup` **on a terminal** asks for the answers. With any flag, or
with nothing attached to stdin, it takes flags and fails on a missing one — so
scripted installs and re-runs from a harness behave exactly as they always
have. `--wizard` forces the questions, `--no-wizard` insists on flags.

The questions only fill in the flags; one code path does the provisioning
either way. What the guided path adds is the parts that aren't flags: it names
the machine and home directory it is about to write to before it writes
anything, prints the browser steps as a checklist and waits rather than
pretending to automate them, and re-asks anything it can check locally — a
non-numeric App ID, a path with no private key at it, a 1Password vault it
can't reach — instead of failing at the end.

What it can't check locally is the credential itself: that takes the GitHub
call `setup` already makes. Nothing has been written to disk by the time it
runs, so a rejected token or a wrong App ID costs you the questions again and
nothing else.

## Introduction

Gives your coding agents (Claude Code, Cursor) their own GitHub identity. Agent
commits land as `your-app[bot]` with you as co-author, instead of impersonating
you — and the credit is yours rather than the tool's, since a commit hook clears
the `Co-Authored-By` a harness stamps for itself. A co-author naming anyone else
is real credit and is left alone. Commits the identity only replays — a
cherry-pick, a revert, a rebase — keep the credit they arrive with.
Everything is scoped to one directory — by default `~/agentic-code/` — and your
own git identity is never touched.

That identity can be a **GitHub App bot** (below — the better default) or a
**[separate GitHub account](#a-separate-github-account-instead-of-an-app)**.
Both kinds can coexist, one per subdirectory.

The tool is tested on macOS and Linux, and stays compatible with the bash 3.2
that ships with macOS.

## Setting up a GitHub App bot

### One-time GitHub setup (two browser steps)

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

### Setup

```bash
./bin/guise setup --owner patricktulskie --app-id 12345 --pem ~/Downloads/your-app.pem
```

What happens: the App's metadata (slug, installation ID, bot user ID) is
discovered from the API, credentials go into 1Password, the PEM is shredded,
helper binaries land in `~/.local/bin`, and a directory-scoped git identity is
wired up for `~/agentic-code/patricktulskie-agent/` — named after the agent
itself, not a generic slot. Setup also drops an `AGENTS.md` (and a
`CLAUDE.md` importing it) into `~/agentic-code/` telling harnesses to use
`guise-gh` — harnesses that stack context files up the directory tree pick it
up for every repo underneath; it never overwrites your edits. It finishes by
running `doctor`, which verifies the whole chain. Safe to re-run any time.

Requires: `gh`, `jq`, `openssl`, `git`, and `op` (1Password CLI, signed in)
unless you use `--store file`.

### Key storage: 1Password or a plain file

By default the secret — an App's private key, or an account's PAT — lives in
1Password and is read on demand, which means a locked vault blocks the agent.
For agents that run unattended, pass `--store file` and it is kept under
`~/.config/guise/keys/` (mode 600) instead — no 1Password involved at use
time. It deliberately does *not* live in `~/agentic-code/`: agents roam that
directory and must not be able to read or accidentally commit it.

### The PEM is only needed once per app

Adding another identity for an app you've already set up (a second
installation, say) reuses the stored key — just omit `--pem`.

## A separate GitHub account (instead of an app)

An App's installation token only works on repos where the app is installed. A
dedicated account can be given access anywhere, which is what you want for repos
you don't control — with one caveat about how its token gets scoped, in step 2.

**1. Create the account** — a normal GitHub signup with its own email address.
GitHub's terms allow one machine account per person alongside your own.

**2. Give it access to the repos — as an org *member*, not an outside
collaborator.** This ordering matters: a fine-grained PAT can only reach repos
owned by the **resource owner** it was issued for, and the resource-owner picker
lists an org only if the account is a member of it. An account added as an
outside collaborator can therefore only issue a token scoped to *itself*, which
reaches nothing the org owns — even with write access to the repo. Add it to a
team; that costs a seat in a paid org.

If you can't add it as a member, a **classic** PAT with the `repo` scope honors
outside-collaborator access without membership or a seat. The tradeoff is
reach: `repo` is all-or-nothing, so there's no per-repo selection.

**3. Issue a fine-grained PAT** *while signed in as that account* — Settings →
Developer settings → Personal access tokens → Fine-grained tokens:

- Resource owner: whoever **owns** the repos the agent will work in — the org,
  not the agent account, for anything org-owned
- Repository access: only the repos the agent should work in
- Repository permissions: Contents **R/W**, Pull requests **R/W**, Issues
  **R/W** (Metadata read comes along automatically)
- Expiration: whatever you'll actually rotate — `doctor` starts failing 30
  days out

Then hand the token to setup as a file, never as a flag value (flags land in
`ps` output and shell history):

```bash
pbpaste > /tmp/pat
./bin/guise setup --kind user --token-file /tmp/pat
```

Setup calls `GET /user` to discover the account's login and numeric user ID,
**refuses the token if it belongs to your own account**, stores it (1Password
by default, or `--store file`), and shreds `/tmp/pat`. The identity is named
after the account, so commits under `~/agentic-code/<login>/` are authored by
it, still with you as co-author.

Org policy may require an owner to approve the token before it works, and a
pending token is indistinguishable from a working one at the agent's end. Both
that and a self-scoped token look fine to every other check and only surface as
a 403 at clone time, so `doctor` verifies the token reaches at least one
repository — see [troubleshooting](docs/troubleshooting.md).

Re-running setup for that identity without `--token-file` reuses the stored
token, so it's safe to re-run any time. Rotating is the same command with a
fresh `--token-file`.

### Which one to use

| | GitHub App bot | Separate account |
|---|---|---|
| Credential | 1-hour token, minted per use | long-lived PAT |
| Repo access | only where the app is installed | collaborator anywhere |
| Signed commits | can't sign; needs a ruleset bypass | `--sign`, own key |
| Seat in a paid org | free | consumes one |
| Rotation | automatic | manual, before the PAT expires |

The app is the better default — nothing standing to steal, no rotation to
remember. Reach for an account when the agent needs to work on repos you can't
install an app on.

## Signed commits

Repos and orgs increasingly require signed commits. A separate GitHub account is
a real account, so it can hold a signing key of its own:

```bash
guise setup --kind user --login your-agent-account --sign
```

That generates an ed25519 key at `~/.config/guise/keys/<identity>.signing`
(mode 600, no passphrase, never leaves the machine), switches the scoped config
to `gpg.format = ssh` with `commit.gpgsign = true`, writes an allowed-signers
file so `git log --show-signature` verifies locally, and prints the public half.

One step is left, and it is manual. Signed in **as the agent account**, go to
github.com/settings/ssh/new, choose **Key type: Signing Key** — not
Authentication Key, they are separate lists — and paste the key `setup` printed.
Until you do, commits still sign but GitHub shows them Unverified, and `doctor`
says so.

### Why that step is manual

Registering a signing key needs an account-level permission that a fine-grained
PAT cannot carry, so there is no credential that could do it for you. That also
means the whole signing path touches no secret at all: the one GitHub call
`guise` makes here is an unauthenticated read of the account's public key
list, to check whether the key is already up there.

The key itself is deliberately the one thing not kept in 1Password. It grants
nothing, it never authenticates anything (`namespaces="git"` limits it to
commits and tags), and replacing it costs one command — so syncing it would only
widen where it can leak from.

### Rotating and turning it off

Delete the key and re-run setup to mint a fresh one; re-running with the key
still in place reuses it, which is what you want, since the old public half is
the one registered on the account:

```bash
rm ~/.config/guise/keys/<identity>.signing*
guise setup --kind user --login your-agent-account --sign
```

`--no-sign` turns it back off, shreds the local private half, and reminds you to
remove the public one from the account. Signing is otherwise sticky: a bare
re-run of `setup` keeps doing whatever that identity already does.

An **App** identity cannot sign — a `your-app[bot]` user has no settings page to
hold a key — and `--sign` is refused for one. Put the app on the signature
ruleset's bypass list instead; see
[docs/troubleshooting.md](docs/troubleshooting.md).

## Daily use

```bash
guise use patricktulskie-agent         # cd ~/agentic-code/patricktulskie-agent
guise clone patricktulskie/some-repo   # → ~/agentic-code/patricktulskie-agent/
cd some-repo
# ... let the agent work; commits are authored by the bot, co-authored by you
guise-gh pr create --fill                 # opens the PR as the bot
```

`guise use` with no name goes to your default identity — the one
`guise default` prints.

It moves the shell you're already in, which needs a small shell function that
`setup` installs to `~/.config/guise/hook.sh` and sources from your `~/.zshrc`
(or `~/.bash_profile`) between `# >>> guise >>>` markers. **It takes effect in
new shells** — right after setup, either open one or `source ~/.zshrc`. Until
then, and in any shell that doesn't load the hook, `use` opens a subshell in the
directory instead and you leave it with `exit`.

Nothing is exported. The directory is what carries the identity — git picks it
up through `includeIf`, `guise-gh` by reading `$PWD` — so there's no stale
variable to follow you back out of the tree. `uninstall` removes the rc lines and
the hook.

The only convention that matters: **agent clones live under `~/agentic-code/`,
your own clones live anywhere else.** Inside that directory every git operation
— from Claude Code, Cursor, or a plain terminal — uses the bot identity with no
harness-specific configuration. Tell each harness one thing: use `guise-gh`
instead of `gh` (a line in `CLAUDE.md` / Cursor rules).

## Commands

| Command | What it does |
|---|---|
| `guise setup` | provision an identity (idempotent); asks for the answers when given no flags on a terminal |
| `guise doctor` | verify everything; non-zero exit on any failure |
| `guise clone <owner/repo>` | clone where the identity applies |
| `guise use [name]` | cd to an identity's directory; the default one if you don't say |
| `guise update` | reinstall helpers, hook, and rendered confs from this copy of the script |
| `guise token` | print the identity's token (debugging / harness use) |
| `guise default [name]` | show or change the identity used when none is named |
| `guise rename <old> <new>` | rename an identity, its directory, and its key files |
| `guise uninstall` | remove all wiring; keys (1Password or file) and clones are left alone |

## Identity names and the default

An identity is named after the agent it belongs to — the app slug for a bot,
the account login for an account — and that name is the directory name, so
clones land in `~/agentic-code/patricktulskie-agent/`. Pass `--name` to
override.

`guise clone` and `guise-gh` take the identity from the directory you're
standing in, so inside `~/agentic-code/someorg/` you get `someorg` without
saying so. Outside the base directory — and for commands with no directory to
read, like `guise token` — they fall back to the default, recorded in
`~/.config/guise/config` as `core.defaultidentity` and set to the first
identity you provision:

```bash
guise default                        # print it
guise default patricktulskie-agent   # change it
```

`setup --default` claims it at provisioning time instead, for when you already
know the new identity should be the one commands fall back to.

Renaming moves everything named after the identity — config section, key file,
rendered git conf, and the directory with your clones in it. Existing installs
made before this behavior are the reason it exists:

```bash
guise rename default patricktulskie-agent
```

## Multiple identities

Each identity gets its own subdirectory. A second installation of the *same*
app (e.g. on an org you belong to) needs no new key:

```bash
guise setup --owner some-org --app-id 12345 --name someorg
guise clone some-org/their-repo --name someorg   # → ~/agentic-code/someorg/
```

`--name` is only needed from outside; run the same clone from inside
`~/agentic-code/someorg/` and it picks that identity on its own.

A different app entirely gets its own `--pem`:

```bash
guise setup --owner patricktulskie --app-id 67890 --pem ~/Downloads/other.pem --name experiments
```

Kinds mix freely — an app bot in one subdirectory, an account in another:

```bash
guise setup --kind user --token-file /tmp/pat --name oss
guise clone someone/their-repo --name oss     # → ~/agentic-code/oss/
```

## Picking up a new version

The helper binaries, the commit hook, and the git config template live inside
`bin/guise` and are written out at install time, so a newer script in this
repo does nothing until you install it:

```bash
git pull && ./bin/guise update
```

`update` rewrites the helpers, the hook, and **every** identity's rendered conf
from the script you ran it with. It reads no credential, makes no API call, and
does not touch `~/.config/guise/config` or anything stored in 1Password — so
it works with the vault locked and the network down. Follow it with
`guise doctor` when you want the whole chain verified.

Re-running `setup` also picks up a new version, but it does more than an update
needs: it reads the identity's stored secret and calls GitHub to rediscover
metadata, and it re-renders only the identity it ran for. Use `setup` when the
credential or the GitHub-side metadata changed; use `update` when only the
script did.

## Contributing to repos the app isn't installed on

An installation token only works on repos where the app is installed. For open
source work that means one of:

- the maintainer installs your agent app on their repo/org (the "Any account"
  setting above makes this possible),
- you fork, install the app on your own fork, push there as the bot, and open
  the PR from the fork, or
- you use a [separate account](#a-separate-github-account-instead-of-an-app),
  which needs no installation on either side.

## When something's off

Run `guise doctor` first — every check prints a remediation hint. Then see
[docs/troubleshooting.md](docs/troubleshooting.md).
