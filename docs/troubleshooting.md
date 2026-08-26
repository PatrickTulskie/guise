# Troubleshooting

Run `agent-id doctor` first — it covers most of these and prints a hint per
failing check. This page is keyed to the failure modes people actually hit.

## Commits or pushes land as *you*, not the bot

**Cause:** the human's cached credentials (osxkeychain) won the credential
lookup, or the repo isn't inside the agent directory at all.

- Check the repo location: identity only applies under `~/agentic-code/<identity>/`.
  `git config user.email` inside the repo should print the bot address.
- Check the helper chain: the rendered conf
  (`~/.config/agent-id/git/<identity>.conf`) must contain an **empty**
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

Re-run `agent-id setup` — it rediscovers the bot user ID from
`GET /users/<slug>%5Bbot%5D` and re-renders the conf. `doctor` has a dedicated
check for this ("app id != bot user id").

## Push rejected: signed commits required

**Cause:** the repo (or its org) has a signature ruleset and the agent isn't
signing.

For a **separate GitHub account**, give it a key of its own:

```bash
agent-id setup --kind user --login <agent-login> --sign
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
`~/.config/agent-id/keys/<identity>.signing.pub`. This step is always manual:
registering a signing key needs an account-level permission that a fine-grained
PAT cannot carry. Re-running `agent-id setup --sign` prints the key again if you
need it.

GitHub also matches the signature against the account owning the commit email,
so a wrong email shows the same symptom — see *PR/commit author shows an
unlinked name*, above.

## The agent account's PAT expired, was revoked, or is about to

`doctor` fails on "token valid and still @`<login>`" when the PAT no longer
works, and on "token not expiring within 30 days" while there is still time.
Both are fixed the same way — issue a fresh fine-grained PAT from the agent
account and re-run setup for that identity:

```bash
pbpaste > /tmp/pat
agent-id setup --kind user --name <identity> --token-file /tmp/pat
```

The git wiring and the identity's directory are untouched; only the stored
secret changes.

## Clone or push fails: "Write access to repository not granted"

**Cause:** the credential is valid but reaches **zero repositories**. Everything
else looks healthy — it authenticates, `GET /user` returns the right login,
every other check passes — which is what makes this one confusing. `doctor`
catches it with "token reaches at least one repository" (account identities) or
"installation reaches at least one repository" (apps).

For an account identity there are two causes, and they look identical from the
agent's side:

- **The token is scoped to the agent account itself.** A fine-grained PAT only
  reaches repos owned by its *resource owner*, and the resource-owner picker
  lists an org only if the account is a **member** of it. An account added as an
  outside collaborator can't pick the org, so its token is self-scoped and
  reaches nothing org-owned — write access on the repo doesn't change that.
- **The token is waiting on org approval.** An org can require an owner to
  approve fine-grained tokens; until that happens the token behaves as if the
  org weren't there.

Tell them apart on the token's own settings page — signed in as the agent
account, Settings → Developer settings → Personal access tokens →
Fine-grained tokens → the token. It names its resource owner, and shows an
approval-pending banner while an owner still has to act. If the resource owner
is the agent account, add the account to the org as a member and issue a fresh
token (or use a classic PAT with `repo` scope — see the README). If it's
pending, ask an owner to approve it.

To check what a credential reaches without waiting for a clone (the token goes
through a config file on a pipe, never `-H`, so it stays out of `ps`):

```bash
curl -s --config <(printf 'header = "Authorization: Bearer %s"\n' "$(agent-id token <identity>)") \
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
run that comparison and warns instead of refusing. Check `agent-id doctor`
once `gh` is authenticated.

## Token expired mid-session

This section is about app identities; account identities hold a standing PAT
that only expires on the date GitHub stamped on it (see above).

Installation tokens live 1 hour. The credential helper mints on demand and
caches for 55 minutes, so a long session should never see an expired token —
git asks the helper on every push. If you exported a token into the
environment (e.g. `GH_TOKEN=$(agent-id token)`), that copy *will* expire;
use `agent-gh`, which mints fresh per invocation, instead of exporting.

If minting itself fails: `agent-id token` prints the error. Usual causes are
1Password locked (`op signin`; doesn't apply to `--store file` identities),
the app uninstalled, or a rotated private key (re-run `setup --pem` with the
new download).

## Cursor (or Claude Code) doesn't pick up the identity

**Cause:** the repo is outside the agent directory. Identity is selected by
`includeIf "gitdir:..."`, not environment variables — deliberately, because
Cursor's agent subprocesses don't reliably inherit exported env.

Move (or re-clone with `agent-id clone`) the repo into
`~/agentic-code/<identity>/`. No harness configuration exists to set; location
is the mechanism.

## `gh` commands act as you, not the bot

Plain `gh` uses your stored login. Use `agent-gh` — it injects a bot token via
`GH_TOKEN`, which `gh` prefers over its own credentials. Put "use `agent-gh`
instead of `gh`" in `CLAUDE.md` and Cursor rules.

## Your own commits broke (signing errors, wrong email)

This tool never edits your global identity — everything is scoped under the
agent directory, and `~/.gitconfig` only gains a marker-delimited include
block. If your own commits changed behavior:

- `git config --show-origin user.email` in one of *your* repos: the origin
  should be your global config, not anything under `~/.config/agent-id/`.
- Same for `commit.gpgsign` and `gpg.format`: a `--sign` identity sets both, but
  only inside `~/agentic-code/<identity>/`.
- `agent-id doctor` runs a "human identity untouched" check.
- Worst case `agent-id uninstall` removes every trace of the wiring.

## CI didn't run on the agent's PR

It should — an App's installation token *does* trigger workflows (unlike
Actions' built-in `GITHUB_TOKEN`). If it didn't, the push probably didn't come
from the bot at all; check the commit author on the PR and see the first
section above.
