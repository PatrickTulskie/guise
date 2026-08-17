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
  printf 'protocol=https\nhost=github.com\n\n' | git credential fill
  ```
  run inside the repo; username must be `x-access-token`.
- Cloned over ssh? ssh authenticates with *your* key. The agent conf rewrites
  `git@github.com:` to https, but a remote hardcoded elsewhere may bypass it.
  `git remote -v` should show https URLs.

## PR/commit author shows an unlinked name with no avatar

**Cause:** the App ID ended up in the commit email instead of the **bot user
ID**. They are different numbers; the email must be
`<botUserId>+<slug>[bot]@users.noreply.github.com`.

Re-run `agent-id setup` — it rediscovers the bot user ID from
`GET /users/<slug>%5Bbot%5D` and re-renders the conf. `doctor` has a dedicated
check for this ("app id != bot user id").

## Push rejected: signed commits required

**Cause:** the repo (or its org) has a signature ruleset and the app isn't on
its bypass list. The bot has no signing key by design.

Fix in the UI: Settings → Rules → Rulesets → *(signature ruleset)* →
Bypass list → Add → Apps → select the agent app → mode **Always**. This is
scoped, named, and reversible.

## Token expired mid-session

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
- `agent-id doctor` runs a "human identity untouched" check.
- Worst case `agent-id uninstall` removes every trace of the wiring.

## CI didn't run on the agent's PR

It should — an App's installation token *does* trigger workflows (unlike
Actions' built-in `GITHUB_TOKEN`). If it didn't, the push probably didn't come
from the bot at all; check the commit author on the PR and see the first
section above.
