# Troubleshooting

Run `guise doctor` first — it covers most of these and prints a hint per
failing check. This page is keyed to the failure modes people actually hit.

## Commits or pushes land as *you*, not the bot

**Cause:** the human's cached credentials (osxkeychain) won the credential
lookup, or the repo isn't inside the agent directory at all.

- Check the repo location: identity only applies under the identity's own
  directory — `guise basedir --name <identity>` prints the workspace it sits
  in, and `guise which` inside the repo names the identity that owns it.
  `git config user.email` inside the repo should print the bot address.
- Check the helper chain: the rendered conf
  (`~/.config/guise/git/<identity>.conf`) must contain an **empty**
  `helper =` line before the real one — that empty line clears inherited
  helpers. Verify with:
  ```bash
  printf 'protocol=https\nhost=github.com\n\n' \
    | git credential fill | sed -n 's/^username=//p'
  ```
  run inside the repo; it must print `x-access-token`. The `sed` matters:
  `git credential fill` prints the resolved *password* too, so without it you
  would echo a live token into your scrollback (and into anything you paste).
- Cloned over ssh? ssh authenticates with *your* key. The agent conf rewrites
  `git@github.com:` to https, but a remote hardcoded elsewhere may bypass it.
  `git remote -v` should show https URLs.

## PR/commit author shows an unlinked name with no avatar

**Cause:** the App ID ended up in the commit email instead of the **bot user
ID**. They are different numbers; the email must be
`<botUserId>+<slug>[bot]@users.noreply.github.com`. For an account identity
the equivalent is `<userId>+<login>@users.noreply.github.com`, where the
numeric user ID comes from `GET /user`.

Re-run `guise setup` — it rediscovers the bot user ID from
`GET /users/<slug>%5Bbot%5D` and re-renders the conf. `doctor` has a dedicated
check for this ("app id != bot user id").

## The commit credits the harness instead of you

**Cause:** an old commit hook. Claude Code and Cursor stamp a `Co-Authored-By`
of their own into the message they hand git, and the hook that shipped before
this one stood down when it saw one — `git interpret-trailers` matches on the
trailer token alone and never looks at who is named, so any co-author at all
meant yours was never added.

The current hook clears the harness trailers by address — the harnesses' own,
and the identity's, which the commit is already authored by — then adds yours.
Any other co-author is left standing, so a trailer that credits a contributor
whose work you reimplemented survives. It is written out at install time, so a
newer script does nothing on its own:

```bash
git pull && ./bin/guise update
```

`doctor`'s "co-author hook installed and executable" check proves a hook is
there, not that it is the current one — if a commit still credits the harness
after an update, check the message the harness passed to `git commit`.

## The trailer credits you on a commit you didn't write

**Cause:** an old commit hook, which added the trailer to every commit the
identity made — including ones it was only replaying. Adopting an outside
contributor's patch keeps them as author and the bot as committer, and the
trailer then named a third person on a change none of them wrote.

The current hook stands down on a replay: a cherry-pick, a revert, a rebase, or
a `--author` that isn't the identity's own address. Update to get it:

```bash
git pull && ./bin/guise update
```

Credit that a replayed commit already carries is left as it is — the hook only
adds your trailer to commits the identity actually authored.

## Push rejected: signed commits required

**Cause:** the repo (or its org) has a signature ruleset and the agent isn't
signing.

For a **separate GitHub account**, give it a key of its own:

```bash
guise setup --login <agent-login> --sign
```

That generates an SSH signing key, switches the scoped config to
`gpg.format = ssh` with `commit.gpgsign = true`, and prints the public half for
you to paste onto the agent account (README → *Signed commits*). `doctor` then
covers it with three checks: key present at mode 600, key registered on the
account, and a real commit signing and verifying inside agent scope.

For an **App**, there is nothing to sign with — a `your-app[bot]` user has no
settings page to hold a signing key, and `--sign` is refused. Put the app on the
ruleset's bypass list instead: Settings → Rules → Rulesets → *(signature
ruleset)* → Bypass list → Add → **Apps** → the agent app → mode **Always**.
Scoped, named, and reversible.

## Commits are signed but GitHub shows them Unverified

**Cause:** the public key isn't on the agent account, or it went into the wrong
list.

`doctor` separates the two halves: "commits sign and verify in agent scope"
passes (git is signing correctly) while "signing key registered on @\<login\>"
fails. Only the second one involves GitHub.

Signed in **as the agent account**, go to github.com/settings/ssh/new, set
**Key type: Signing Key** — not Authentication Key; they are separate lists, and
an authentication key verifies nothing — and paste
`~/.config/guise/keys/<identity>.signing.pub`. This step is always manual:
registering a signing key takes a scope (`write:ssh_signing_key`) guise never
asks the token for. Re-running `guise setup --sign` prints the key again if you
need it.

GitHub also matches the signature against the account owning the commit email,
so a wrong email shows the same symptom — see *PR/commit author shows an
unlinked name*, above.

## The agent account's PAT expired, was revoked, or is about to

`doctor` fails on "token valid and still @`<login>`" when the PAT no longer
works, and on "token not expiring within 30 days" while there is still time.
Both are fixed the same way — issue a fresh PAT from the agent account and re-run setup for that identity:

```bash
pbpaste > /tmp/pat
guise setup --name <identity> --token-file /tmp/pat
```

The git wiring and the identity's directory are untouched; only the stored
secret changes.

## Clone or push fails: "Write access to repository not granted"

**Cause:** the credential is valid but reaches **zero repositories**. Everything
else looks healthy — it authenticates, `GET /user` returns the right login,
every other check passes — which is what makes this one confusing. `doctor`
catches it with "token reaches at least one repository" (account identities) or
"installation reaches at least one repository" (apps).

For an account identity, the usual causes:

- **The invite was never accepted.** Being added as a collaborator does nothing
  until the account accepts — signed in as the agent account, check
  github.com/notifications or the repo's invitation link.
- **The classic token is missing the `repo` scope.** Signed in as the agent
  account, Settings → Developer settings → Personal access tokens → Tokens
  (classic) → the token lists its scopes. Tick `repo` and regenerate.
- **A fine-grained token is scoped to the agent account itself.** It only
  reaches repos owned by its *resource owner*, and GitHub offers an org there
  only if the account is a **member**, so an outside collaborator's token
  reaches nothing the org owns. An org can also hold fine-grained tokens for
  owner approval. Either way, a classic token with `repo` sidesteps both.

To check what a credential reaches without waiting for a clone (the token goes
through a config file on a pipe, never `-H`, so it stays out of `ps`):

```bash
curl -s --config <(printf 'header = "Authorization: Bearer %s"\n' "$(guise token <identity>)") \
  "https://api.github.com/user/repos?per_page=1"
```

An empty array `[]` is the failure. For an app identity, ask
`https://api.github.com/installation/repositories` instead — `"total_count": 0`
means the app is installed but has no repositories selected, fixed under the
installation's settings, "Only select repositories".

## Setup refuses the token: "belongs to your own account"

The PAT was issued while signed in as *you*, not as the agent account — which
would hand the agent your identity and your access. Sign in as the agent
account (a separate browser profile is the least painful way) and issue the
token there.

If you're setting this up on a machine where `gh` isn't logged in, setup can't
run that comparison and warns instead of refusing. Check `guise doctor`
once `gh` is authenticated.

## Token expired mid-session

This section is about app identities; account identities hold a standing PAT
that only expires on the date GitHub stamped on it (see above).

Installation tokens live 1 hour. The credential helper mints on demand and
caches for 55 minutes, so a long session should never see an expired token —
git asks the helper on every push. If you exported a token into the
environment (e.g. `GH_TOKEN=$(guise token)`), that copy *will* expire;
use `guise-gh`, which mints fresh per invocation, instead of exporting.

If minting itself fails: `guise token` prints the error. Usual causes are
1Password locked (`op signin`; only for `--store op` identities, and for
`--store op-cache` ones on their first read of a login session), the app
uninstalled, or a rotated private key (re-run `setup --pem` with the new
download).

## The agent keeps using a secret you replaced in 1Password

**Cause:** the identity reads through op-cache (`--store op-cache`), which holds
a value in memory until its daemon exits and can't forget just one reference.
Rotating through `guise setup --token-file` (or `--pem`) empties it for you;
editing the item in 1Password by hand does not.

```bash
op-cache clear
```

drops everything op-cache holds, so the next read asks 1Password again.
`doctor`'s "1Password token reachable through op-cache" passes either way — it
proves a value comes back, not which one — so "token valid and still
@\<login\>" is the check that catches a stale PAT.

## Cursor (or Claude Code) doesn't pick up the identity

**Cause:** the repo is outside the agent directory. Identity is selected by
`includeIf "gitdir:..."`, not environment variables — deliberately, because
Cursor's agent subprocesses don't reliably inherit exported env.

Move (or re-clone with `guise clone`) the repo into the identity's directory
under `guise basedir`. No harness configuration exists to set; location is the
mechanism.

## A clone stopped using the identity after the workspace moved

**Cause:** the workspace directory changed but that clone didn't come along, so
it now sits outside every `includeIf` scope and commits as you.

`guise basedir <path>` moves the identity directories for you, so this is what
a hand-moved clone — or a `core.basedir` edited directly in
`~/.config/guise/config` — looks like afterwards. `guise doctor` lists the
offenders by path under "no clones stranded outside an identity directory".

Either move the clone under the identity's current directory, or point the
workspace back at where the clones actually are:

```bash
guise basedir ~/where/they/are      # or --name <identity> for just one
```

## `guise use` opens a subshell instead of moving the one you're in

**Cause:** the shell hook isn't loaded. `setup` writes it to
`~/.config/guise/hook.sh` and sources it from your rc, but a shell that was
already running never read that line.

Open a new shell, or `source ~/.zshrc`. `guise doctor` reports this as a
`warn`, not a failure — the identity chain works either way, and the subshell
(which you leave with `exit`) is the deliberate fallback.

If it still doesn't take:

- `grep guise ~/.zshrc` should show the sourced line between
  `# >>> guise >>>` markers. Setup only edits the rc for zsh and bash; under
  any other shell it prints the line for you to add yourself.
- On macOS, bash reads `~/.bash_profile` rather than `~/.bashrc`, which is where
  setup puts it.
- `command guise` must resolve — the hook defines a function that shadows
  `guise` and delegates to the real script, so `~/.local/bin` has to be on
  `PATH`.

## Setup or uninstall stops: "has a stray guise marker"

`setup` keeps its lines in `~/.gitconfig` and your shell rc between
`# >>> guise >>>` and `# <<< guise <<<`, and finds them again by those
markers. If a file has an unpaired marker, two blocks, or one out of order,
there is no single block to replace and no safe way to guess which lines are
yours — so the command stops and changes nothing.

`grep -n 'guise >>>\|guise <<<' ~/.gitconfig ~/.zshrc` shows what is
there. Usually it is an orphan left by a hand edit that deleted half a block, or
a config merged from two machines. Delete the stray markers and the lines
between them, leaving either one complete pair or none, then re-run.

This is the one case where the tool refuses a file rather than rewriting it: a
guess here would take out lines you wrote.

## `gh` commands act as you, not the bot

Plain `gh` uses your stored login. Use `guise-gh` — it injects a bot token via
`GH_TOKEN`, which `gh` prefers over its own credentials. Put "use `guise-gh`
instead of `gh`" in `CLAUDE.md` and Cursor rules.

`guise-gh` never falls back to that login. If it can't get the identity's token
it exits before `gh` runs, with `guise-token`'s error above its own; fix that
one (`guise doctor` names it) and re-run. Helpers installed before this check
need a `guise update` to pick it up.

## Your own commits broke (signing errors, wrong email)

This tool never edits your global identity — everything is scoped under the
agent directory, and `~/.gitconfig` only gains a marker-delimited include
block. If your own commits changed behavior:

- `git config --show-origin user.email` in one of *your* repos: the origin
  should be your global config, not anything under `~/.config/guise/`.
- Same for `commit.gpgsign` and `gpg.format`: a `--sign` identity sets both, but
  only inside that identity's own directory.
- `guise doctor` runs a "human identity untouched" check.
- Worst case `guise uninstall` removes every trace of the wiring.

## CI didn't run on the agent's PR

It should — an App's installation token *does* trigger workflows (unlike
Actions' built-in `GITHUB_TOKEN`). If it didn't, the push probably didn't come
from the bot at all; check the commit author on the PR and see the first
section above.
