#!/usr/bin/env bash
# Shell test harness (bats not assumed). Runs everything in a sandboxed $HOME
# with stubbed `op`, `curl`, and `gh`; git, openssl, jq, shred are the real ones.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_PATH="$PATH"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
expect() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi }
expect_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (got '$got', want '$want')"; fi
}
expect_fail() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$desc"; else ok "$desc"; fi }

new_sandbox() {
  SB=$(mktemp -d)
  export HOME="$SB/home"
  mkdir -p "$HOME"
  export XDG_CACHE_HOME="$HOME/.cache"
  export OP_FAKE_DIR="$SB/op"; mkdir -p "$OP_FAKE_DIR"
  export CURL_LOG="$SB/curl.log"; : > "$CURL_LOG"
  # What the fake GitHub has on the agent account's SSH signing keys page.
  export SIGNING_KEYS_FILE="$SB/signing_keys"; : > "$SIGNING_KEYS_FILE"
  export PATH="$ROOT/tests/stubs:$REAL_PATH"
  export FAKE_APP_ID=1111 FAKE_SLUG=test-agent FAKE_OWNER=PatrickTulskie FAKE_INSTALL_ID=2222 FAKE_BOT_ID=3333
  export FAKE_USER_ID=4444 FAKE_LOGIN=patrick-agent
  unset FAKE_GH_LOGIN FAKE_TOKEN_EXPIRES 2>/dev/null || true
  export OP_FAKE_ACCOUNT=my.1password.com
  unset GUISE_IDENTITY GUISE_CONFIG GUISE_CO_AUTHOR 2>/dev/null || true
  # Pins which rc setup writes the shell-hook line into, so the suite asserts
  # the same path on macOS and on Linux. zsh need not be installed for this.
  export SHELL=/bin/zsh
  git config --global user.name "Human"
  git config --global user.email "human@example.com"
  git config --global commit.gpgsign true
  git config --global init.defaultBranch main
  openssl genrsa -out "$SB/key.pem" 2048 2>/dev/null
}

# No --coauthor: the hook's fallback to global user.name/email is under test.
run_setup() {
  "$ROOT/bin/guise" setup --owner patricktulskie --app-id 1111 \
    --op-account my.1password.com "$@" </dev/null
}

run_setup_user() {
  "$ROOT/bin/guise" setup --kind user \
    --op-account my.1password.com "$@" </dev/null
}

agent() { "$ROOT/bin/guise" "$@" </dev/null; }

new_token_file() { printf 'github_pat_stub123\n' > "$1"; }

cfg() { git config -f "$HOME/.config/guise/config" --get "$1"; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# setup names an identity after the account it belongs to, so these are the
# names the stubbed app slug and account login produce.
APP_IDENT=test-agent
USER_IDENT=patrick-agent

snapshot() {
  cat "$HOME/.gitconfig" \
      "$HOME/.zshrc" \
      "$HOME/.config/guise/hook.sh" \
      "$HOME/.config/guise/config" \
      "$HOME/.config/guise/gitconfig" \
      "$HOME/.config/guise/git/$APP_IDENT.conf" \
      "$HOME/.config/guise/git/agent-hooks/prepare-commit-msg" \
      "$HOME/.local/bin/guise-token" \
      "$HOME/.local/bin/guise-credential" \
      "$HOME/.local/bin/guise-gh" 2>/dev/null | shasum | cut -d' ' -f1
}

# --- version --------------------------------------------------------------------
# Answerable before anything is installed: every other subcommand needs a config,
# and "which version is this?" is exactly what you ask of a copy you just cloned.
echo "version:"
new_sandbox
ver=$(agent --version)
expect_eq "--version reports the version" "$ver" "guise 0.1.0"
expect_eq "the subcommand form agrees" "$(agent version)" "$ver"
expect_eq "and the short flag" "$(agent -v)" "$ver"
expect_eq "the usage banner carries the same one" \
  "$(agent help | head -1 | cut -d' ' -f1-2)" "$ver"
expect "no config was needed to answer" test ! -e "$HOME/.config/guise/config"

# --- setup provisions everything --------------------------------------------
echo "setup:"
new_sandbox
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "setup exits 0" "$?" "0"
expect "config file written" test -f "$HOME/.config/guise/config"
expect_eq "slug discovered from API" "$(cfg identity.$APP_IDENT.slug)" "test-agent"
expect_eq "installation id discovered" "$(cfg identity.$APP_IDENT.installationid)" "2222"
expect_eq "bot user id discovered (not app id)" "$(cfg identity.$APP_IDENT.botuserid)" "3333"
expect_eq "basedir defaults to ~/agentic-code" "$(cfg core.basedir)" "$HOME/agentic-code"
expect "PEM shredded after storing" test ! -e "$SB/key.pem"
expect "private key landed in 1Password" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "helpers installed" test -x "$HOME/.local/bin/guise-token"
expect "credential helper installed" test -x "$HOME/.local/bin/guise-credential"
expect "guise-gh installed" test -x "$HOME/.local/bin/guise-gh"
expect "hook installed" test -x "$HOME/.config/guise/git/agent-hooks/prepare-commit-msg"
expect "identity dir created" test -d "$HOME/agentic-code/$APP_IDENT"
expect "AGENTS.md dropped in workspace" test -f "$HOME/agentic-code/AGENTS.md"
expect "CLAUDE.md imports AGENTS.md" grep -q '@AGENTS.md' "$HOME/agentic-code/CLAUDE.md"
expect_eq "exactly one marker block in ~/.gitconfig" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect "shell hook written" test -f "$HOME/.config/guise/hook.sh"
expect_eq "exactly one marker block in ~/.zshrc" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.zshrc")" "1"

# --- idempotency -------------------------------------------------------------
echo "idempotency:"
snap1=$(snapshot)
echo "custom rules" > "$HOME/agentic-code/AGENTS.md"
run_setup >/dev/null 2>&1
expect_eq "re-run without --pem exits 0" "$?" "0"
"$ROOT/bin/guise" setup --name "$APP_IDENT" </dev/null >/dev/null 2>&1
expect_eq "a re-run by name alone finds the app's owner and App ID" "$?" "0"
"$ROOT/bin/guise" setup </dev/null >/dev/null 2>&1
expect_eq "and so does a bare re-run of the default" "$?" "0"
expect_eq "re-run changes no artifact" "$(snapshot)" "$snap1"
expect_eq "still exactly one marker block" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect_eq "and the rc line is not stacked up either" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.zshrc")" "1"
expect_eq "edited AGENTS.md not overwritten" \
  "$(cat "$HOME/agentic-code/AGENTS.md")" "custom rules"

# --- second identity ---------------------------------------------------------
echo "multiple identities:"
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store op --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
expect_eq "second identity setup exits 0" "$?" "0"
expect_eq "two includeIf blocks in owned gitconfig" \
  "$(grep -c includeIf "$HOME/.config/guise/gitconfig")" "2"
expect_eq "~/.gitconfig untouched by second identity" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect "platform dir created" test -d "$HOME/agentic-code/platform"
run_setup --store op --name reused >/dev/null 2>&1
expect_eq "new identity without --pem reuses the stored key" "$?" "0"
expect_eq "reused identity fully discovered" "$(cfg identity.reused.installationid)" "2222"

# --- identity applies inside scope, hook behaves -----------------------------
echo "scoped identity + trailer hook:"
repo="$HOME/agentic-code/$APP_IDENT/hooktest"
git init -q "$repo"
expect_eq "bot identity applies inside scope" \
  "$(git -C "$repo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
expect_eq "gpgsign off inside scope" "$(git -C "$repo" config --get commit.gpgsign)" "false"
expect_eq "human identity intact outside scope" \
  "$(git -C "$SB" config --get user.email)" "human@example.com"
( cd "$repo" && echo x > f && git add f && git commit -q -m "test commit" )
expect_eq "commit authored by bot" \
  "$(git -C "$repo" log -1 --format='%an')" "test-agent[bot]"
expect_eq "co-author trailer added on commit -m" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by: Human <human@example.com>$')" "1"
( cd "$repo" && git commit -q --amend --no-edit )
expect_eq "trailer not duplicated on --amend" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "1"

# A harness hands git a message that already credits itself. The human has to
# displace that, not defer to it -- interpret-trailers on its own defers,
# because it matches the token and never looks at who is named.
( cd "$repo" && echo y > g && git add g && git commit -q -m "harness commit

Co-Authored-By: Cursor Agent <cursoragent@cursor.com>" )
expect_eq "harness co-author replaced by the human" \
  "$(git -C "$repo" log -1 --format=%B | grep -i '^Co-authored-by:')" \
  "Co-authored-by: Human <human@example.com>"

# Replaying someone else's commit makes the identity its committer, not an
# author. Crediting the human there claims a share of a patch neither of them
# wrote -- once via --author, and once via the cherry-pick that adopts it.
( cd "$repo" && git checkout -q -b outside HEAD~1 && echo z > h && git add h \
  && git commit -q -m "outside contribution" --author="Outsider <out@example.com>" )
expect_eq "no trailer on a commit made with --author" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "0"
( cd "$repo" && git checkout -q - && git cherry-pick outside >/dev/null )
expect_eq "cherry-pick keeps the original author" \
  "$(git -C "$repo" log -1 --format='%an')" "Outsider"
expect_eq "and no trailer credits the human for it" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "0"

# A clean revert leaves no REVERT_HEAD behind -- the sequencer keeps that marker
# only while it is stopped -- so the generated message is the only thing left to
# recognise the replay by.
( cd "$repo" && git revert --no-edit HEAD >/dev/null )
expect_eq "no trailer on a clean revert" \
  "$(git -C "$repo" log -1 --format=%B | grep -c '^Co-authored-by:')" "0"

# Reimplementing a contribution leaves no commit of theirs to preserve, so the
# trailer is the only credit its author gets -- the hook clears the harness and
# the identity's own redundant credit, and nothing else. The bot address is the
# reason this matches whole addresses and not a pattern: it is full of regex.
( cd "$repo" && echo w > i && git add i && git commit -q -m "reimplemented contribution

Co-Authored-By: Claude <noreply@anthropic.com>
Co-authored-by: test-agent[bot] <3333+test-agent[bot]@users.noreply.github.com>
Co-authored-by: Contributor <c@example.com>" )
expect_eq "the contributor and the human are the only co-authors left" \
  "$(git -C "$repo" log -1 --format=%B | grep -i '^Co-authored-by:' | tr '\n' '|')" \
  "Co-authored-by: Contributor <c@example.com>|Co-authored-by: Human <human@example.com>|"

# A missing global identity must not abort the commit: git config exits 1 on an
# unset key and the hook runs under set -e. Driven directly rather than through a
# commit, so unsetting the global identity can't reorder ~/.gitconfig and leave
# [user] winning over the include.
hook="$HOME/.config/guise/git/agent-hooks/prepare-commit-msg"
mkdir -p "$SB/nohome"
printf 'a commit subject\n' > "$SB/msg.txt"
( HOME="$SB/nohome" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "hook exits 0 when there is no identity to credit" "$?" "0"
expect_eq "and leaves the message without a trailer" \
  "$(grep -c '^Co-authored-by:' "$SB/msg.txt")" "0"
printf 'a commit subject\n' > "$SB/msg.txt"
( GUISE_CO_AUTHOR="Someone <s@example.com>" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "and still adds the trailer when one is available" \
  "$(grep -c '^Co-authored-by: Someone <s@example.com>$' "$SB/msg.txt")" "1"

# Clearing the co-author token is not licence to touch the rest of the block.
printf 'a commit subject\n\nSigned-off-by: Someone <s@example.com>\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$SB/msg.txt"
( GUISE_CO_AUTHOR="Human <human@example.com>" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "an unrelated trailer survives the strip" \
  "$(grep -c '^Signed-off-by: Someone <s@example.com>$' "$SB/msg.txt")" "1"
expect_eq "and the harness co-author is gone, whatever its casing" \
  "$(grep -i '^Co-authored-by:' "$SB/msg.txt")" "Co-authored-by: Human <human@example.com>"

# addIfDifferent compares the trailer verbatim, so a message that already
# credits the human in another spelling would otherwise get a second one.
printf 'a commit subject\n\nCo-Authored-By: HUMAN <Human@Example.com>\n' > "$SB/msg.txt"
( GUISE_CO_AUTHOR="Human <human@example.com>" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "the human's own trailer is not duplicated by a different spelling" \
  "$(grep -i -c '^Co-authored-by:' "$SB/msg.txt")" "1"

# --- token cache -------------------------------------------------------------
echo "token cache:"
rm -rf "$XDG_CACHE_HOME/guise"; : > "$CURL_LOG"
t1=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
t2=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "second call returns cached token" "$t1" "$t2"
expect_eq "only one mint against the API" "$(grep -c access_tokens "$CURL_LOG")" "1"

# --- doctor ------------------------------------------------------------------
echo "doctor:"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes on a healthy install" "$?" "0"

# A valid credential that reaches zero repos passes every other check and only
# fails at clone time -- doctor has to catch it.
FAKE_REPO_COUNT=0 "$ROOT/bin/guise" doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when the installation reaches no repos" "$?" "1"
expect "the failure names the installation reachability check" \
  grep -q "FAIL  installation reaches at least one repository" "$SB/doctor.out"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes again once the installation has a repo" "$?" "0"

# --- file key store ----------------------------------------------------------
echo "file key store:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "file-store setup exits 0" "$?" "0"
keyfile="$HOME/.config/guise/keys/$APP_IDENT.pem"
expect "key file written" test -f "$keyfile"
expect_eq "key file mode 600" \
  "$(stat -c '%a' "$keyfile" 2>/dev/null || stat -f '%Lp' "$keyfile")" "600"
expect_eq "keysource recorded" "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "nothing written to 1Password" test ! -e "$OP_FAKE_DIR/Private/test-agent"
expect "PEM shredded after storing" test ! -e "$SB/key.pem"
t=$("$HOME/.local/bin/guise-token" "$APP_IDENT")
expect_eq "token mints from file key" "${t:0:4}" "ghs_"
run_setup >/dev/null 2>&1
expect_eq "re-run without --store keeps the file store" "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "re-run did not move the key into 1Password" test ! -e "$OP_FAKE_DIR/Private/test-agent"
run_setup --store file --name second >/dev/null 2>&1
expect_eq "second file identity reuses key without --pem" "$?" "0"
expect "second identity got its own key file" test -f "$HOME/.config/guise/keys/second.pem"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes with file store" "$?" "0"
FAKE_STAT_GNU=1 "$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor reads app-key permissions with GNU stat semantics" "$?" "0"
"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect "uninstall keeps key files" test -f "$keyfile"
expect "uninstall removes config file" test ! -e "$HOME/.config/guise/config"
expect "uninstall removes rendered git dir" test ! -e "$HOME/.config/guise/git"

# --- user account identity ---------------------------------------------------
echo "user account identity:"
new_sandbox
printf 'github_pat_stub123\n' > "$SB/pat.txt"
"$ROOT/bin/guise" setup --store op --token-file "$SB/pat.txt" \
  --op-account my.1password.com </dev/null >/dev/null 2>&1
expect_eq "setup with no app flags sets up an account" "$?" "0"
expect_eq "kind recorded" "$(cfg identity.$USER_IDENT.kind)" "user"
expect_eq "login discovered from the token" "$(cfg identity.$USER_IDENT.login)" "patrick-agent"
expect_eq "user id discovered" "$(cfg identity.$USER_IDENT.userid)" "4444"
expect_eq "token expiry recorded" \
  "$(cfg identity.$USER_IDENT.tokenexpires)" "2099-01-01 00:00:00 UTC"
expect "token stored in 1Password" test -f "$OP_FAKE_DIR/Private/patrick-agent/token"
expect "token file shredded" test ! -e "$SB/pat.txt"
expect_eq "token helper returns the PAT verbatim" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_stub123"
expect "PAT is not cached to disk" test ! -e "$XDG_CACHE_HOME/guise/$USER_IDENT.token.json"

repo="$HOME/agentic-code/$USER_IDENT/usertest"
git init -q "$repo"
expect_eq "account identity applies inside scope" \
  "$(git -C "$repo" config --get user.email)" "4444+patrick-agent@users.noreply.github.com"
expect_eq "commits are authored by the account, not a bot" \
  "$(git -C "$repo" config --get user.name)" "patrick-agent"
"$ROOT/bin/guise" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor passes for a user identity" "$?" "0"

FAKE_REPO_COUNT=0 "$ROOT/bin/guise" doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when the PAT reaches no repos" "$?" "1"
expect "the failure names the token reachability check" \
  grep -q "FAIL  token reaches at least one repository" "$SB/doctor.out"
"$ROOT/bin/guise" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor passes again once the PAT reaches a repo" "$?" "0"

"$ROOT/bin/guise" setup --kind user </dev/null >/dev/null 2>&1
expect_eq "re-run without --token-file reuses the stored token" "$?" "0"

# App and user identities have to coexist: they share basedir and ~/.gitconfig.
run_setup --store op --name bot --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "app identity alongside a user identity" "$?" "0"
expect_eq "both identities in the owned gitconfig" \
  "$(grep -c includeIf "$HOME/.config/guise/gitconfig")" "2"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes with both kinds present" "$?" "0"

# --- user identity guardrails ------------------------------------------------
echo "user identity guardrails:"
printf 'github_pat_other\n' > "$SB/pat2.txt"
FAKE_GH_LOGIN=patrick-agent "$ROOT/bin/guise" setup --kind user --name mine \
  --token-file "$SB/pat2.txt" </dev/null >/dev/null 2>&1
expect_eq "refuses a token for your own account" "$?" "1"
expect "refused setup leaves the token file alone" test -f "$SB/pat2.txt"
"$ROOT/bin/guise" setup --kind user --name mine --login someone-else \
  --token-file "$SB/pat2.txt" </dev/null >/dev/null 2>&1
expect_eq "refuses a token that isn't the --login account" "$?" "1"
"$ROOT/bin/guise" setup --kind user --name mine --app-id 1111 </dev/null >/dev/null 2>&1
expect_eq "rejects app-only flags on a user identity" "$?" "1"
git config -f "$HOME/.config/guise/config" identity.$USER_IDENT.tokenexpires "2000-01-01 00:00:00 UTC"
"$ROOT/bin/guise" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor fails on a PAT inside its last 30 days" "$?" "1"

# --- user identity with the file store ---------------------------------------
echo "user identity, file store:"
new_sandbox
printf 'github_pat_filestore\n' > "$SB/pat.txt"
"$ROOT/bin/guise" setup --kind user --store file --token-file "$SB/pat.txt" \
  </dev/null >/dev/null 2>&1
expect_eq "file-store user setup exits 0" "$?" "0"
tokenfile="$HOME/.config/guise/keys/$USER_IDENT.token"
expect "token file written" test -f "$tokenfile"
expect_eq "token file mode 600" \
  "$(stat -c '%a' "$tokenfile" 2>/dev/null || stat -f '%Lp' "$tokenfile")" "600"
expect "nothing written to 1Password" test ! -e "$OP_FAKE_DIR/Private/patrick-agent"
expect_eq "token helper reads the file" \
  "$("$HOME/.local/bin/guise-token" "$USER_IDENT")" "github_pat_filestore"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes with a file-stored PAT" "$?" "0"
FAKE_STAT_GNU=1 "$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor reads token permissions with GNU stat semantics" "$?" "0"

# The store is settled only after the identity name is, so an unrelated
# 1Password default can't quietly route a new identity's secret into a vault.
run_setup --store op --default --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "app setup into 1Password as the default exits 0" "$?" "0"
run_setup --name third >/dev/null 2>&1
expect_eq "new identity does not inherit the default's 1Password store" \
  "$(cfg identity.third.keysource)" "file"
expect "new identity's key written to disk" test -f "$HOME/.config/guise/keys/third.pem"
run_setup >/dev/null 2>&1
expect_eq "re-running the app identity keeps 1Password" \
  "$(cfg identity.$APP_IDENT.keysource)" "op"
"$ROOT/bin/guise" setup --kind user </dev/null >/dev/null 2>&1
expect_eq "re-running the user identity keeps its file store" \
  "$(cfg identity.$USER_IDENT.keysource)" "file"

# --- identity naming + configurable default ----------------------------------
echo "identity naming and default:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "identity is named after the app slug" "$(cfg identity.test-agent.slug)" "test-agent"
expect "directory is named after the agent" test -d "$HOME/agentic-code/test-agent"
expect "no 'default' directory is created" test ! -e "$HOME/agentic-code/default"
expect_eq "first identity becomes the default" "$(cfg core.defaultidentity)" "test-agent"
expect_eq "'default' subcommand reports it" "$("$ROOT/bin/guise" default)" "test-agent"
expect_eq "token with no identity resolves the default" \
  "$("$HOME/.local/bin/guise-token")" "$("$HOME/.local/bin/guise-token" test-agent)"

openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name explicit --pem "$SB/key2.pem" >/dev/null 2>&1
expect "--name still wins over the derived name" test -d "$HOME/agentic-code/explicit"
expect_eq "a later identity does not steal the default" "$(cfg core.defaultidentity)" "test-agent"
"$ROOT/bin/guise" default explicit >/dev/null 2>&1
expect_eq "default can be repointed" "$(cfg core.defaultidentity)" "explicit"
openssl genrsa -out "$SB/key3.pem" 2048 2>/dev/null
run_setup --store file --name claimed --pem "$SB/key3.pem" --default >/dev/null 2>&1
expect_eq "--default claims the default identity" "$(cfg core.defaultidentity)" "claimed"
"$ROOT/bin/guise" default nonesuch >/dev/null 2>&1
expect_eq "default rejects an unknown identity" "$?" "1"

# --- rename -------------------------------------------------------------------
echo "rename:"
"$ROOT/bin/guise" default test-agent >/dev/null 2>&1
mkdir -p "$HOME/agentic-code/test-agent/someclone"
"$ROOT/bin/guise" rename test-agent renamed >/dev/null 2>&1
expect_eq "rename exits 0" "$?" "0"
expect "clones move with the identity" test -d "$HOME/agentic-code/renamed/someclone"
expect "old directory is gone" test ! -e "$HOME/agentic-code/test-agent"
expect_eq "config section renamed" "$(cfg identity.renamed.slug)" "test-agent"
expect_eq "old config section gone" "$(cfg identity.test-agent.slug 2>/dev/null)" ""
expect "key file renamed" test -f "$HOME/.config/guise/keys/renamed.pem"
expect_eq "keyfile path updated" \
  "$(cfg identity.renamed.keyfile)" "$HOME/.config/guise/keys/renamed.pem"
expect "rendered conf renamed" test -f "$HOME/.config/guise/git/renamed.conf"
expect "old rendered conf gone" test ! -e "$HOME/.config/guise/git/test-agent.conf"
expect_eq "default follows the rename" "$(cfg core.defaultidentity)" "renamed"
git init -q "$HOME/agentic-code/renamed/newrepo"
expect_eq "identity applies under the new directory" \
  "$(git -C "$HOME/agentic-code/renamed/newrepo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
"$ROOT/bin/guise" doctor >/dev/null 2>&1
expect_eq "doctor passes after rename" "$?" "0"
"$ROOT/bin/guise" rename renamed explicit >/dev/null 2>&1
expect_eq "rename refuses a name already in use" "$?" "1"
"$ROOT/bin/guise" rename nonesuch whatever >/dev/null 2>&1
expect_eq "rename refuses an unknown identity" "$?" "1"

# --- basedir --------------------------------------------------------------------
echo "workspace directory:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "basedir prints the shared workspace" "$(agent basedir)" "$HOME/agentic-code"
git init -q "$HOME/agentic-code/$APP_IDENT/someclone"

agent basedir "$HOME/src" >/dev/null 2>&1
expect_eq "basedir exits 0" "$?" "0"
expect_eq "the new path is recorded" "$(cfg core.basedir)" "$HOME/src"
# The point of the whole subcommand: a clone left behind under the old path
# would fall out of includeIf scope and start committing as the human.
expect "clones move with the setting" test -d "$HOME/src/$APP_IDENT/someclone"
expect "the old directory is gone" test ! -e "$HOME/agentic-code/$APP_IDENT"
expect_eq "identity applies under the new path" \
  "$(git -C "$HOME/src/$APP_IDENT/someclone" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
expect "AGENTS.md lands in the new workspace" test -f "$HOME/src/AGENTS.md"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes after the move" "$?" "0"
# Re-running with the path it already has moves nothing and breaks nothing.
agent basedir "$HOME/src" >/dev/null 2>&1
expect_eq "setting the path it already has is a no-op" "$?" "0"
expect "clones untouched by the no-op" test -d "$HOME/src/$APP_IDENT/someclone"

# Workspace roots are user-chosen paths, so a space in one must survive the
# move, the includeIf, and the walk doctor does.
agent basedir "$HOME/my agents" >/dev/null 2>&1
expect "a path with a space moves the clones" test -d "$HOME/my agents/$APP_IDENT/someclone"
expect_eq "and git still resolves the identity there" \
  "$(git -C "$HOME/my agents/$APP_IDENT/someclone" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
agent doctor >/dev/null 2>&1
expect_eq "and doctor passes" "$?" "0"
agent basedir "$HOME/src" >/dev/null 2>&1

# A destination that sits inside a directory the same plan is moving: the first
# mv would succeed and the second land a tree inside itself, stranding the first
# identity under the second's scope with the config still saying the old thing.
# Nothing may move at all.
openssl genrsa -out "$SB/keyz.pem" 2048 2>/dev/null
run_setup --store file --name zeta --pem "$SB/keyz.pem" >/dev/null 2>&1
git init -q "$HOME/src/zeta/zclone"
expect_fail "basedir refuses a new root inside an identity that is also moving" \
  agent basedir "$HOME/src/zeta"
expect "and moves nothing when it refuses" test -d "$HOME/src/$APP_IDENT/someclone"
expect "including the identity the path named" test -d "$HOME/src/zeta/zclone"
expect_eq "with the setting untouched" "$(cfg core.basedir)" "$HOME/src"

# The same overlap reached through a symlink. Compared as typed, ~/link sits
# outside every identity directory; mv follows the link and lands inside one.
ln -s "$HOME/src/zeta" "$HOME/zlink"
expect_fail "basedir refuses a symlinked root that resolves into a moving identity" \
  agent basedir "$HOME/zlink"
expect "and still moves nothing" test -d "$HOME/src/$APP_IDENT/someclone"
expect "including through the link" test -d "$HOME/src/zeta/zclone"
# And the same overlap spelled with . and .. in a part of the path that does not
# exist yet, which no amount of resolving the existing prefix would catch.
expect_fail "basedir refuses an overlap reached through .." \
  agent basedir "$HOME/src/missing/../zeta"
expect_fail "basedir refuses an overlap reached through ." \
  agent basedir "$HOME/src/./zeta"
expect "and neither spelling moved anything" test -d "$HOME/src/$APP_IDENT/someclone"

# A symlinked root that resolves somewhere harmless is still a fine answer --
# the check must reject the overlap, not the symlink.
mkdir -p "$SB/realroot"
ln -s "$SB/realroot" "$HOME/goodlink"
agent basedir "$HOME/goodlink" >/dev/null 2>&1
expect_eq "but a symlinked root pointing somewhere else is accepted" "$?" "0"
expect "and the clones land through it" test -d "$SB/realroot/$APP_IDENT/someclone"
agent basedir "$HOME/src" >/dev/null 2>&1

# An identity staying put because it has its own workspace, but living inside
# one that is leaving: its clones would ride along out of their own scope.
agent basedir "$HOME/src/$APP_IDENT/nested" --name zeta >/dev/null 2>&1
expect "the nested identity moved" test -d "$HOME/src/$APP_IDENT/nested/zeta/zclone"
expect_fail "basedir refuses to move a directory another identity lives inside" \
  agent basedir "$HOME/faraway"
expect "leaving both where they were" test -d "$HOME/src/$APP_IDENT/nested/zeta/zclone"
agent basedir --unset --name zeta >/dev/null 2>&1

expect_fail "basedir refuses a relative path" agent basedir relative/path
mkdir -p "$HOME/occupied/$APP_IDENT"
expect_fail "basedir refuses an occupied destination" agent basedir "$HOME/occupied"
expect_eq "and changes nothing when it refuses" "$(cfg core.basedir)" "$HOME/src"
expect "and leaves the clones where they were" test -d "$HOME/src/$APP_IDENT/someclone"

# --- one workspace per identity -------------------------------------------------
echo "per-identity workspace:"
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
git init -q "$HOME/src/platform/theirclone"
agent basedir "$HOME/work" --name platform >/dev/null 2>&1
expect_eq "--name records an override" "$(cfg identity.platform.basedir)" "$HOME/work"
expect "the named identity moves" test -d "$HOME/work/platform/theirclone"
expect "and the others stay where they are" test -d "$HOME/src/$APP_IDENT/someclone"
expect_eq "the shared setting is untouched" "$(cfg core.basedir)" "$HOME/src"
expect_eq "basedir --name reports the override" "$(agent basedir --name platform)" "$HOME/work"
expect_eq "and falls back to the shared one for anyone else" \
  "$(agent basedir --name $APP_IDENT)" "$HOME/src"
expect_eq "the override wins in git, under the new root" \
  "$(git -C "$HOME/work/platform/theirclone" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
expect_eq "which resolves the identity from the overridden path" \
  "$(cd "$HOME/work/platform/theirclone" && agent which)" "platform"
expect_eq "and the other identity from the shared one" \
  "$(cd "$HOME/src/$APP_IDENT/someclone" && agent which)" "$APP_IDENT"
expect_fail "which fails outside every identity directory" \
  env -u GUISE_IDENTITY bash -c "cd \"$HOME\" && \"$ROOT/bin/guise\" which"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes with two workspaces" "$?" "0"
expect_fail "basedir refuses --unset without --name" agent basedir --unset
expect_fail "basedir refuses a path and --unset together" agent basedir "$HOME/x" --unset
expect_fail "basedir refuses an unknown identity" agent basedir "$HOME/x" --name nonesuch

agent basedir --unset --name platform >/dev/null 2>&1
expect_eq "--unset drops the override" "$(cfg identity.platform.basedir 2>/dev/null)" ""
expect "and moves the identity back under the shared workspace" \
  test -d "$HOME/src/platform/theirclone"
expect "leaving nothing behind" test ! -e "$HOME/work/platform"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes after --unset" "$?" "0"

# Nested workspaces: the identity whose directory is the longest prefix of the
# path wins, not whichever one is listed first.
echo "nested workspaces:"
agent basedir "$HOME/src/nested" --name platform >/dev/null 2>&1
mkdir -p "$HOME/src/nested/platform/deep"
expect_eq "the innermost identity claims the path" \
  "$(cd "$HOME/src/nested/platform/deep" && agent which)" "platform"
agent basedir --unset --name platform >/dev/null 2>&1

# --- guise-gh picks the identity up from the directory --------------------------
# Two accounts with different stored tokens, so the token gh is handed says
# which identity guise-gh resolved.
echo "guise-gh identity inference:"
new_sandbox
printf 'github_pat_one\n' > "$SB/pat1"
printf 'github_pat_two\n' > "$SB/pat2"
FAKE_LOGIN=agent-one FAKE_USER_ID=4001 \
  run_setup_user --store file --token-file "$SB/pat1" >/dev/null 2>&1
FAKE_LOGIN=agent-two FAKE_USER_ID=4002 \
  run_setup_user --store file --token-file "$SB/pat2" >/dev/null 2>&1
gh_token_in() { (cd "$1" && "$HOME/.local/bin/guise-gh" echo-token); }
expect_eq "guise-gh uses the identity owning the directory" \
  "$(gh_token_in "$HOME/agentic-code/agent-two")" "github_pat_two"
expect_eq "and the default from outside the workspace" \
  "$(gh_token_in "$HOME")" "github_pat_one"
agent basedir "$HOME/elsewhere" --name agent-two >/dev/null 2>&1
expect_eq "and follows an identity to its own workspace" \
  "$(gh_token_in "$HOME/elsewhere/agent-two")" "github_pat_two"
# The helpers have always read GUISE_CONFIG. guise-gh now resolves the identity
# through `guise which`, so guise itself has to read the same config -- or the
# two disagree and gh runs as whoever the home config calls the default.
cp "$HOME/.config/guise/config" "$SB/alt-config"
git config -f "$SB/alt-config" core.basedir "$HOME/altroot"
# agent-two picked up a workspace of its own above; in this config it follows
# the shared root, which is what makes the two configs disagree about the path.
git config -f "$SB/alt-config" --unset identity.agent-two.basedir
mkdir -p "$HOME/altroot/agent-two"
expect_eq "guise-gh resolves against GUISE_CONFIG, not the home config" \
  "$(cd "$HOME/altroot/agent-two" && GUISE_CONFIG="$SB/alt-config" \
      "$HOME/.local/bin/guise-gh" echo-token)" "github_pat_two"
expect_eq "and guise which answers from it too" \
  "$(cd "$HOME/altroot/agent-two" && GUISE_CONFIG="$SB/alt-config" \
      "$ROOT/bin/guise" which)" "agent-two"

expect_eq "GUISE_IDENTITY still overrides the directory" \
  "$(cd "$HOME/agentic-code/agent-one" && GUISE_IDENTITY=agent-two "$HOME/.local/bin/guise-gh" echo-token)" \
  "github_pat_two"

# --- doctor notices a clone that fell out of scope ------------------------------
echo "stranded clones:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
git init -q "$HOME/agentic-code/orphan"
agent doctor > "$SB/stranded.out" 2>&1
expect_eq "a repo outside every identity directory does not fail doctor" "$?" "0"
expect "but doctor warns about it by path" \
  grep -q "$HOME/agentic-code/orphan" "$SB/stranded.out"
rm -rf "$HOME/agentic-code/orphan"
agent doctor > "$SB/stranded.out" 2>&1
expect "and says nothing once it is gone" \
  grep -q "^  ok    no clones stranded" "$SB/stranded.out"

# --- clone ---------------------------------------------------------------------
# Real git, no network: rewrite the github.com URL clone builds to a local bare
# repo, so what gets asserted is where the clone lands.
echo "clone:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
mkdir -p "$SB/origins/owner"
for r in one two three four five; do git init -q --bare "$SB/origins/owner/$r.git"; done
git config --global url."$SB/origins/".insteadOf "https://github.com/"

( cd "$HOME/agentic-code/platform" && agent clone owner/one ) >/dev/null 2>&1
expect "clone from inside an agent directory uses that agent" \
  test -d "$HOME/agentic-code/platform/one/.git"
expect "and not the default identity" test ! -e "$HOME/agentic-code/$APP_IDENT/one"
( cd "$HOME/agentic-code/platform" && agent clone owner/two --name "$APP_IDENT" ) >/dev/null 2>&1
expect "--name still wins over the current directory" \
  test -d "$HOME/agentic-code/$APP_IDENT/two/.git"
mkdir -p "$HOME/agentic-code/notanidentity"
( cd "$HOME/agentic-code/notanidentity" && agent clone owner/three ) >/dev/null 2>&1
expect "a directory under the base dir that is not an identity falls back" \
  test -d "$HOME/agentic-code/$APP_IDENT/three/.git"
( cd "$HOME" && agent clone owner/four ) >/dev/null 2>&1
expect "clone from outside the base directory uses the default" \
  test -d "$HOME/agentic-code/$APP_IDENT/four/.git"

# An identity with a workspace of its own: both the destination and the
# identity inferred from the current directory come from the override.
agent basedir "$HOME/own-root" --name platform >/dev/null 2>&1
git init -q --bare "$SB/origins/owner/six.git"
( cd "$HOME/own-root/platform" && agent clone owner/six ) >/dev/null 2>&1
expect "clone follows an identity to its own workspace" \
  test -d "$HOME/own-root/platform/six/.git"
expect "and the earlier clones came along" test -d "$HOME/own-root/platform/one/.git"
agent basedir --unset --name platform >/dev/null 2>&1
expect "--unset brings them back under the shared workspace" \
  test -d "$HOME/agentic-code/platform/six/.git"

# setup keeps the path it was given, so both spellings of the same basedir have
# to resolve the same identity.
git config -f "$HOME/.config/guise/config" core.basedir "$HOME/agentic-code/"
( cd "$HOME/agentic-code/platform" && agent clone owner/five ) >/dev/null 2>&1
expect "a trailing slash on basedir still selects the current identity" \
  test -d "$HOME/agentic-code/platform/five/.git"

# A basedir of / puts identity directories at the root, so this one clone
# lands outside the sandbox by definition. Keep the destination unpredictable
# and take it away again.
root_dest=$(mktemp -d /tmp/guise-root.XXXXXX)
root_repo=${root_dest##*/}
# clone refuses an existing destination, even an empty one.
rmdir "$root_dest"
git init -q --bare "$SB/origins/owner/$root_repo.git"
git config -f "$HOME/.config/guise/config" --rename-section identity.platform identity.tmp
git config -f "$HOME/.config/guise/config" core.basedir /
root_cwd=$(mktemp -d /tmp/guise-root.XXXXXX)
( cd "$root_cwd" && agent clone "owner/$root_repo" ) >/dev/null 2>&1
expect "a root basedir treats an absolute current directory as contained" \
  test -d "$root_dest/.git"
rm -rf "$root_cwd" "$root_dest"

# --- use ----------------------------------------------------------------------
# `use` replaces itself with $SHELL, so stand a recording script in for one and
# read back where it landed.
echo "use:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
cat > "$SB/recording-shell" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$PWD" > "$SB/use.pwd"
printf '%s\n' "\${GUISE_IDENTITY:-}" > "$SB/use.identity"
EOF
chmod +x "$SB/recording-shell"

SHELL="$SB/recording-shell" "$ROOT/bin/guise" use platform </dev/null >/dev/null 2>&1
expect_eq "use lands in the named identity's directory" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/platform"
# Nothing is exported: the directory is what carries the identity, so there is
# no stale variable to follow you out of the tree.
expect_eq "and exports nothing to go stale" "$(cat "$SB/use.identity")" ""

rm -f "$SB/use.pwd"
SHELL="$SB/recording-shell" "$ROOT/bin/guise" use </dev/null >/dev/null 2>&1
expect_eq "no name lands in the default identity's directory" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/$APP_IDENT"

# Retargeting the default moves where a bare `use` lands, which is what tells
# the config apart from any first-identity fallback.
rm -f "$SB/use.pwd"
agent default platform >/dev/null
SHELL="$SB/recording-shell" "$ROOT/bin/guise" use </dev/null >/dev/null 2>&1
expect_eq "and follows the default when it moves" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/platform"

# Nothing configured and more than one identity: there is no right guess.
git config -f "$HOME/.config/guise/config" --unset core.defaultidentity
expect_fail "use refuses to guess with no default and several identities" agent use
agent default "$APP_IDENT" >/dev/null

expect_fail "use refuses an unknown identity" agent use nonesuch

# The shell hook: `use --emit-shell` prints the cd, the sourced function runs it
# in the shell you are already in. Everything else falls through to the script.
expect_eq "--emit-shell prints just the cd, shell-quoted" \
  "$(agent use platform --emit-shell)" "cd '$HOME/agentic-code/platform'"
expect_eq "sourcing the hook makes use cd the running bash" \
  "$(PATH="$HOME/.local/bin:$PATH" bash -c \
      'cd "$HOME"; . "$HOME/.config/guise/hook.sh"; guise use platform; printf %s "$PWD"')" \
  "$HOME/agentic-code/platform"
expect_eq "and passes every other subcommand straight through" \
  "$(PATH="$HOME/.local/bin:$PATH" bash -c \
      '. "$HOME/.config/guise/hook.sh"; guise default')" \
  "$APP_IDENT"
expect_fail "and reports failure without moving the shell" \
  env PATH="$HOME/.local/bin:$PATH" bash -c \
      '. "$HOME/.config/guise/hook.sh"; guise use nonesuch'
if command -v zsh >/dev/null; then
  expect_eq "sourcing the hook makes use cd the running zsh" \
    "$(PATH="$HOME/.local/bin:$PATH" zsh -c \
        'cd "$HOME"; . "$HOME/.config/guise/hook.sh"; guise use platform; printf %s "$PWD"')" \
    "$HOME/agentic-code/platform"
else
  echo "  skip  sourcing the hook makes use cd the running zsh (zsh not installed)"
fi

# The hook evals what --emit-shell printed, so an apostrophe anywhere in the
# path has to survive the round trip rather than ending the quoted word.
# Emitted by /bin/bash on purpose: bash 3.2 is the floor this script targets,
# and its pattern substitution is where the escaping goes wrong. The eval that
# checks the result can run under any bash -- a mangled quote is a syntax error
# in every one of them.
quoted_base="$HOME/pat's ünïcode guise"
git config -f "$HOME/.config/guise/config" core.basedir "$quoted_base"
emitted=$(/bin/bash "$ROOT/bin/guise" use platform --emit-shell </dev/null)
expect_eq "a quote in the path survives the eval the hook does" \
  "$(cd "$HOME" && eval "$emitted" 2>/dev/null; printf %s "$PWD")" \
  "$quoted_base/platform"
git config -f "$HOME/.config/guise/config" core.basedir "$HOME/agentic-code"

# A shell hook nobody sourced is a missing convenience, not a broken identity,
# so doctor says so without failing.
printf 'alias ll="ls -l"\n' > "$HOME/.zshrc"
agent doctor > "$SB/shellhook.out" 2>&1
expect_eq "doctor still exits 0 with the rc line gone" "$?" "0"
expect "and reports the shell hook as a warning, not a failure" \
  grep -q "^  warn  shell hook" "$SB/shellhook.out"

# An unrecognized shell has no rc to edit; setup must say so and carry on.
SHELL=/usr/bin/fish run_setup --store file --name fishy > "$SB/fishy.out" 2>&1
expect_eq "setup under an unrecognized shell still exits 0" "$?" "0"
expect "and points at the hook to source by hand" \
  grep -q "unrecognized shell" "$SB/fishy.out"

# --- symlinked rc and gitconfig ------------------------------------------------
# Dotfiles are usually symlinks into a dotfiles repo. Editing the link instead of
# its target both breaks the link and leaves the block in the file the shell
# really reads, so assert on the target and on the link surviving.
echo "symlinked dotfiles:"
new_sandbox
mkdir -p "$HOME/dotfiles"
printf 'alias ll="ls -l"\n' > "$HOME/dotfiles/zshrc"
cp "$HOME/.gitconfig" "$HOME/dotfiles/gitconfig"
cp "$HOME/dotfiles/zshrc" "$SB/zshrc.pre"
cp "$HOME/dotfiles/gitconfig" "$SB/gitconfig.pre"
chmod 640 "$HOME/dotfiles/zshrc"
rm -f "$HOME/.zshrc" "$HOME/.gitconfig"
ln -s "$HOME/dotfiles/zshrc" "$HOME/.zshrc"
ln -s "$HOME/dotfiles/gitconfig" "$HOME/.gitconfig"
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect "setup leaves ~/.zshrc a symlink" test -L "$HOME/.zshrc"
expect "setup leaves ~/.gitconfig a symlink" test -L "$HOME/.gitconfig"
expect_eq "the rc block lands in the file the link points at" \
  "$(grep -cF '# >>> guise >>>' "$HOME/dotfiles/zshrc")" "1"
expect_eq "and the gitconfig block does too" \
  "$(grep -cF '# >>> guise >>>' "$HOME/dotfiles/gitconfig")" "1"
expect_eq "the target's mode is untouched" "$(file_mode "$HOME/dotfiles/zshrc")" "640"

# The replace path, which only runs when a block is already there and differs.
# It spans lines, and `awk -v` cannot carry a newline -- BWK awk on macOS errors
# out -- so a stale block has to survive a re-run.
printf 'alias ll="ls -l"\n\n# >>> guise >>>\nstale\n# <<< guise <<<\n' \
  > "$HOME/dotfiles/zshrc"
run_setup --store file > "$SB/replace.out" 2>&1
expect_eq "re-running setup over a stale block exits 0" "$?" "0"
expect_eq "the stale block is replaced, not duplicated" \
  "$(grep -cF '# >>> guise >>>' "$HOME/dotfiles/zshrc")" "1"
expect "and the replacement is the real source line" \
  grep -qF 'hook.sh' "$HOME/dotfiles/zshrc"
expect "through the symlink, which is still a symlink" test -L "$HOME/.zshrc"

"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect "uninstall leaves ~/.zshrc a symlink" test -L "$HOME/.zshrc"
expect "uninstall leaves ~/.gitconfig a symlink" test -L "$HOME/.gitconfig"
expect "rc target byte-identical to pre-setup" \
  cmp -s "$HOME/dotfiles/zshrc" "$SB/zshrc.pre"
expect "gitconfig target byte-identical to pre-setup" \
  cmp -s "$HOME/dotfiles/gitconfig" "$SB/gitconfig.pre"

# --- stray markers -------------------------------------------------------------
# The block is found by its markers, so a file where they do not form one clean
# pair cannot be edited without guessing. Guessing here means deleting lines the
# human wrote, so refuse the file and leave it alone.
echo "stray markers:"
new_sandbox
printf 'alias ll="ls -l"\n# >>> guise >>>\nexport IMPORTANT=1\n' > "$HOME/.zshrc"
cp "$HOME/.zshrc" "$SB/zshrc.pre"
run_setup --store file --pem "$SB/key.pem" > "$SB/stray.out" 2>&1
expect_eq "setup fails on an rc with an orphan start marker" "$?" "1"
expect "and names the file to fix" \
  grep -qF "error: ~/.zshrc has a stray guise marker" "$SB/stray.out"
expect "and the lines below the orphan are still there" \
  cmp -s "$HOME/.zshrc" "$SB/zshrc.pre"

new_sandbox
printf '\n# >>> guise >>>\nstale\n# <<< guise <<<\n' >> "$HOME/.gitconfig"
printf '\n# >>> guise >>>\nstale\n# <<< guise <<<\n' >> "$HOME/.gitconfig"
cp "$HOME/.gitconfig" "$SB/gitconfig.pre"
run_setup --store file --pem "$SB/key.pem" > "$SB/dup.out" 2>&1
expect_eq "setup fails on a gitconfig carrying two blocks" "$?" "1"
expect "and leaves it untouched rather than picking one" \
  cmp -s "$HOME/.gitconfig" "$SB/gitconfig.pre"

# A line that only quotes the marker text is ordinary shell, not wiring. Marker
# discovery compares whole lines for that reason, and setup has to sail past it.
new_sandbox
printf 'echo "# >>> guise >>>"\nalias ll="ls -l"\n' > "$HOME/.zshrc"
run_setup --store file --pem "$SB/key.pem" > "$SB/quoted.out" 2>&1
expect_eq "setup ignores a line that merely quotes a marker" "$?" "0"
expect "and the line is still there afterwards" \
  grep -qxF 'echo "# >>> guise >>>"' "$HOME/.zshrc"
expect_eq "with exactly one real block added below it" \
  "$(grep -cxF '# >>> guise >>>' "$HOME/.zshrc")" "1"
"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect_eq "and uninstall takes the block, not the quoted line" \
  "$(cat "$HOME/.zshrc")" "$(printf 'echo "# >>> guise >>>"\nalias ll="ls -l"')"

# Restore is byte-for-byte, which includes a file that never ended in a newline:
# awk's print would quietly add one and uninstall would hand back a longer file.
new_sandbox
printf 'alias ll="ls -l"' > "$HOME/.zshrc"
cp "$HOME/.zshrc" "$SB/zshrc.pre"
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect "an rc with no trailing newline comes back byte-identical" \
  cmp -s "$HOME/.zshrc" "$SB/zshrc.pre"

# --- commit signing ----------------------------------------------------------
# A separate GitHub account is a real account, so it can hold an SSH signing key
# and GitHub can mark its commits Verified. App identities cannot: there is no
# settings page behind a foo[bot] user.
echo "commit signing (user identity):"
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >"$SB/sign.out" 2>&1
# Non-zero, and correctly so: the key is not on the account yet, which is a real
# gap doctor has to report. Putting it there is a browser step.
expect_eq "setup ends non-zero while the key is not on the account" "$?" "1"
signkey="$HOME/.config/guise/keys/$USER_IDENT.signing"
expect_eq "signing recorded in config" "$(cfg identity.$USER_IDENT.signing)" "ssh"
expect_eq "signingkey points into the keys dir" "$(cfg identity.$USER_IDENT.signingkey)" "$signkey"
expect "private half generated" test -f "$signkey"
expect "public half written alongside" test -f "$signkey.pub"
expect_eq "private half is mode 600" \
  "$(stat -c '%a' "$signkey" 2>/dev/null || stat -f '%Lp' "$signkey")" "600"
expect "an ed25519 key" grep -q '^ssh-ed25519 ' "$signkey.pub"
# Agents roam the workspace; a signing key there is one they could commit.
expect_eq "nothing signing-shaped under the agent workspace" \
  "$(find "$HOME/agentic-code" -name '*.signing*' | wc -l | tr -d ' ')" "0"

# Registering a signing key needs an account-level permission no fine-grained PAT
# can carry, so setup asks rather than tries -- and the whole signing path stays
# credential-free.
expect "setup prints the public key to paste" grep -qF \
  "$(awk '{print $1" "$2}' "$signkey.pub")" "$SB/sign.out"
expect "and names the Signing Key dropdown, not the authentication one" \
  grep -q 'Key type: Signing Key' "$SB/sign.out"
expect_eq "nothing was ever posted to the key API" \
  "$(grep -c '/user/ssh_signing_keys' "$CURL_LOG")" "0"
expect_eq "the registration check is the only failure" \
  "$(agent doctor 2>&1 | grep -c '^  FAIL')" "1"
expect_eq "and it names the account" \
  "$(agent doctor 2>&1 | grep -c "FAIL  signing key registered on @$USER_IDENT")" "1"
expect_eq "while commits already sign and verify locally" \
  "$(agent doctor 2>&1 | grep -c 'ok    commits sign and verify in agent scope')" "1"

signrepo="$HOME/agentic-code/$USER_IDENT/signed"
git init -q "$signrepo"
expect_eq "gpgsign on inside scope" "$(git -C "$signrepo" config --get commit.gpgsign)" "true"
expect_eq "tags sign too" "$(git -C "$signrepo" config --get tag.gpgsign)" "true"
expect_eq "ssh signature format inside scope" "$(git -C "$signrepo" config --get gpg.format)" "ssh"
expect_eq "signing key resolves inside scope" \
  "$(git -C "$signrepo" config --get user.signingkey)" "$signkey"
expect_eq "human gpgsign untouched outside scope" \
  "$(git -C "$SB" config --get commit.gpgsign)" "true"
expect_fail "and no ssh format leaked into the human's config" \
  git -C "$SB" config --get gpg.format
( cd "$signrepo" && echo x > f && git add f && git commit -q -m "signed commit" )
expect_eq "the commit carries a good signature" \
  "$(git -C "$signrepo" log -1 --format='%G?')" "G"
expect "allowed signers file names the agent's commit email" \
  grep -q "^4444+$USER_IDENT@users\.noreply\.github\.com namespaces=\"git\" ssh-ed25519 " \
  "$HOME/.config/guise/git/$USER_IDENT.allowed_signers"

# Paste the key into the account's signing keys page, the way a human does.
echo "once the key is on the account:"
awk '{print $1" "$2}' "$signkey.pub" >> "$SIGNING_KEYS_FILE"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes" "$?" "0"
FAKE_STAT_GNU=1 agent doctor >/dev/null 2>&1
expect_eq "doctor reads signing-key permissions with GNU stat semantics" "$?" "0"
run_setup_user --login "$USER_IDENT" >"$SB/sign2.out" 2>&1
expect_eq "a bare re-run exits 0 now" "$?" "0"
expect "and says the key is already registered" \
  grep -q "already registered on @$USER_IDENT" "$SB/sign2.out"
expect_eq "and keeps signing on" "$(cfg identity.$USER_IDENT.signing)" "ssh"
# Re-running setup is the advertised repair action: it must not mint a new key,
# since the old public half is the one registered on the account.
fp=$(ssh-keygen -lf "$signkey.pub" | awk '{print $2}')
run_setup_user --login "$USER_IDENT" >/dev/null 2>&1
expect_eq "and reuses the same key" "$(ssh-keygen -lf "$signkey.pub" | awk '{print $2}')" "$fp"

# Signing locally and being Verified on GitHub fail separately, and the checks
# have to tell them apart.
: > "$SIGNING_KEYS_FILE"
agent doctor >/dev/null 2>&1
expect_eq "doctor fails again if the key is removed from the account" "$?" "1"
awk '{print $1" "$2}' "$signkey.pub" >> "$SIGNING_KEYS_FILE"

echo "turning signing back off:"
new_token_file "$SB/pat2.txt"
run_setup_user --name gated --store file --sign --token-file "$SB/pat2.txt" >/dev/null 2>&1
expect "a second signing identity got its own key" \
  test -f "$HOME/.config/guise/keys/gated.signing"
expect_eq "with signing on" "$(cfg identity.gated.signing)" "ssh"
run_setup_user --name gated --no-sign >/dev/null 2>&1
expect_eq "--no-sign exits 0" "$?" "0"
expect_fail "signing unset in config" cfg identity.gated.signing
expect_fail "signingkey unset too" cfg identity.gated.signingkey
expect "local private key shredded" test ! -e "$HOME/.config/guise/keys/gated.signing"
expect "public half removed with it" test ! -e "$HOME/.config/guise/keys/gated.signing.pub"
expect "allowed signers file removed" test ! -e "$HOME/.config/guise/git/gated.allowed_signers"
gatedrepo="$HOME/agentic-code/gated/scoped"
git init -q "$gatedrepo"
expect_eq "gpgsign back off inside scope" \
  "$(git -C "$gatedrepo" config --get commit.gpgsign)" "false"
expect_fail "no ssh signing format left behind" git -C "$gatedrepo" config --get gpg.format
agent doctor --name gated >/dev/null 2>&1
expect_eq "doctor passes with signing off again" "$?" "0"

# Shredding the key before the config stops pointing at it would leave a conf
# that still signs, naming a key that is gone. Force a die after that point --
# the token comes from a file, but storing it needs 1Password.
echo "a --no-sign that dies partway:"
new_token_file "$SB/pat3.txt"
run_setup_user --name opsign --store op --sign --token-file "$SB/pat3.txt" >/dev/null 2>&1
opkey="$HOME/.config/guise/keys/opsign.signing"
expect "an op-store identity gets a signing key too" test -f "$opkey"
new_token_file "$SB/pat4.txt"
OP_FAKE_FORBID=1 run_setup_user --name opsign --no-sign \
  --token-file "$SB/pat4.txt" >/dev/null 2>&1
expect_eq "setup dies when 1Password is unreachable" "$?" "1"
expect "the signing key survived the failure" test -f "$opkey"
expect_eq "and the config still says it signs" "$(cfg identity.opsign.signing)" "ssh"
new_token_file "$SB/pat5.txt"
run_setup_user --name opsign --no-sign --token-file "$SB/pat5.txt" >/dev/null 2>&1
expect_eq "a --no-sign that completes exits 0" "$?" "0"
expect "and only then is the key shredded" test ! -e "$opkey"

echo "signing refusals:"
run_setup --pem "$SB/key.pem" --sign >/dev/null 2>&1
expect_eq "--sign is refused on an app identity" "$?" "1"
expect "and refuses before touching the PEM" test -f "$SB/key.pem"

echo "signing survives rename:"
agent rename "$USER_IDENT" bot-renamed >/dev/null 2>&1
expect_eq "rename exits 0" "$?" "0"
expect_eq "signingkey follows the rename" \
  "$(cfg identity.bot-renamed.signingkey)" "$HOME/.config/guise/keys/bot-renamed.signing"
expect "renamed private key exists" test -f "$HOME/.config/guise/keys/bot-renamed.signing"
expect "renamed public key exists" test -f "$HOME/.config/guise/keys/bot-renamed.signing.pub"
expect "stale allowed signers removed" \
  test ! -e "$HOME/.config/guise/git/$USER_IDENT.allowed_signers"
renamedsign="$HOME/agentic-code/bot-renamed/scoped"
git init -q "$renamedsign"
( cd "$renamedsign" && echo x > f && git add f && git commit -q -m "still signed" )
expect_eq "commits still verify under the new name" \
  "$(git -C "$renamedsign" log -1 --format='%G?')" "G"
# Signing keys are credentials like any other, so uninstall leaves them where
# they are -- same policy as the 1Password items and the on-disk PATs.
agent uninstall --yes >"$SB/uninstall.out" 2>&1
expect "uninstall leaves the signing key alone" \
  test -f "$HOME/.config/guise/keys/bot-renamed.signing"
expect "and names the public half still on the account" \
  grep -q 'public signing key on the agent account' "$SB/uninstall.out"

# --- help is inert --------------------------------------------------------------
# The usage text is an unquoted heredoc, so anything expandable in it runs when
# help does -- a backtick once turned `guise help` into a `guise setup`. Nothing
# on stderr is the cheap way to hold that line whatever gets added to the text.
echo "help:"
new_sandbox
help_err=$("$ROOT/bin/guise" help 2>&1 >/dev/null </dev/null)
expect_eq "help writes nothing to stderr" "$help_err" ""
expect_eq "help exits 0" "$?" "0"
expect "help still lists the commands" \
  bash -c "'$ROOT/bin/guise' help 2>/dev/null | grep -q '^  setup'"
expect "and help provisions nothing" test ! -e "$HOME/.config/guise/config"

# --- guided setup --------------------------------------------------------------
# The wizard reads its answers from stdin whether or not that is a terminal, so
# the suite walks the same prompts a human does. Answers are positional, and
# each block below lists them in order.
echo "guided setup:"

# kind, app-exists, owner, app id, pem, browser pause, store, name, workspace,
# go
wizard() { "$ROOT/bin/guise" setup --wizard; }

new_sandbox
printf 'app\ny\npatricktulskie\n1111\n%s\nok\nfile\n\n\ny\n' "$SB/key.pem" \
  | wizard >/dev/null 2>&1
expect_eq "a guided app setup exits 0" "$?" "0"
# The whole design claim: the wizard only fills in flags, so it has to land the
# byte-identical config a flag-driven setup would.
expect_eq "app metadata still discovered from the API" "$(cfg identity.$APP_IDENT.slug)" "test-agent"
expect_eq "installation id discovered" "$(cfg identity.$APP_IDENT.installationid)" "2222"
expect_eq "the store chosen at the prompt is honoured" \
  "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "the PEM is shredded like any other" test ! -e "$SB/key.pem"
expect "identity dir created" test -d "$HOME/agentic-code/$APP_IDENT"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes on a guided install" "$?" "0"

# A second app identity: the stored key is offered rather than asked for, so
# there is no pem answer here -- reuse, browser pause, store, name, ...
printf 'new\napp\ny\npatricktulskie\n1111\ny\nok\nfile\nsecond\n\nn\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "a second identity for the same app exits 0" "$?" "0"
expect "and reuses the stored key without asking for a PEM" test -d "$HOME/agentic-code/second"
expect_eq "without stealing the default" "$(cfg core.defaultidentity)" "$APP_IDENT"
printf 'new\napp\ny\npatricktulskie\n1111\ny\nok\n\nthird\n\n\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "unless asked to, which is what enter does" "$(cfg core.defaultidentity)" "third"

# A name and a workspace typed at the prompts, rather than derived.
new_sandbox
printf 'app\ny\npatricktulskie\n1111\n%s\nok\nfile\nchosen\n%s\ny\n' \
  "$SB/key.pem" "$HOME/elsewhere" | wizard >/dev/null 2>&1
expect "an answered name becomes the identity" test -d "$HOME/elsewhere/chosen"
expect_eq "and an answered workspace becomes the basedir" "$(cfg core.basedir)" "$HOME/elsewhere"

# Declining at the summary has to leave no trace -- the whole point of asking
# before doing anything.
new_sandbox
printf 'app\ny\npatricktulskie\n1111\n%s\nok\nfile\n\n\nn\n' "$SB/key.pem" \
  | wizard >/dev/null 2>&1
expect_eq "declining at the summary fails" "$?" "1"
expect "and writes no config" test ! -e "$HOME/.config/guise/config"
expect "and leaves the PEM alone" test -f "$SB/key.pem"

# Anything checkable without the network is re-asked, not fatal: a bad choice,
# a non-numeric app id, and a path with no key at it. A menu also takes the
# number of its choice.
printf 'maybe\n2\ny\npatricktulskie\nnotanumber\n1111\n/nonesuch.pem\n%s\nok\nfile\n\n\ny\n' \
  "$SB/key.pem" | wizard >/dev/null 2>&1
expect_eq "a bad choice, app id, and PEM path are all re-asked" "$?" "0"
expect_eq "and the run still completes correctly" "$(cfg identity.$APP_IDENT.installationid)" "2222"

# kind, account-exists, login, browser pause, token, sign, store,
# name, workspace, go, signing-key browser pause, check again or skip
new_sandbox
printf 'user\ny\npatrick-agent\nok\ngithub_pat_wizard\n\n\n\n\ny\nok\nskip\n' \
  | wizard >/dev/null 2>&1
# Non-zero, and correctly so: the key was skipped rather than added to the
# account, so doctor still reports the one gap setup can't close.
expect_eq "a guided account setup ends on the one gap it can't close" "$?" "1"
expect_eq "kind recorded" "$(cfg identity.$USER_IDENT.kind)" "user"
expect_eq "user id discovered from the API" "$(cfg identity.$USER_IDENT.userid)" "4444"
# Typed at the prompt, carried in the process, stored once: never in argv and
# never in a file of its own on the way there.
expect_eq "the pasted token is what got stored" \
  "$(cat "$HOME/.config/guise/keys/$USER_IDENT.token")" "github_pat_wizard"
expect_eq "and kept in a file unless told otherwise" "$(cfg identity.$USER_IDENT.keysource)" "file"
expect_eq "signing is on unless declined" "$(cfg identity.$USER_IDENT.signing)" "ssh"
expect "signing key generated" test -f "$HOME/.config/guise/keys/$USER_IDENT.signing"
printf '%s\n' "$(awk '{print $1" "$2}' "$HOME/.config/guise/keys/$USER_IDENT.signing.pub")" \
  >> "$SIGNING_KEYS_FILE"
agent doctor >/dev/null 2>&1
expect_eq "doctor passes on a guided account install" "$?" "0"

# Re-running for an identity that exists asks which one and nothing else: every
# other answer is already in the config, and a bare re-run is the documented
# repair action.
snap_guided=$(snapshot)
printf '%s\n' "$USER_IDENT" | wizard >/dev/null 2>&1
expect_eq "re-running an existing identity through the wizard exits 0" "$?" "0"
expect_eq "and changes nothing" "$(snapshot)" "$snap_guided"

# The same re-run, but for an app identity -- whose owner and App ID cmd_setup
# needs and the config already holds.
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
snap_app=$(snapshot)
printf '%s\n' "$APP_IDENT" | wizard >/dev/null 2>&1
expect_eq "re-running an app identity through the wizard exits 0" "$?" "0"
expect_eq "without asking for the owner and App ID again" "$(snapshot)" "$snap_app"
expect_eq "and the app metadata is intact" "$(cfg identity.$APP_IDENT.appid)" "1111"


# Entering the human's own account is a local mistake like any other, so the
# wizard asks again instead of ending the run.
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
printf 'user\ny\nPatrickTulskie\npatrick-agent\nok\ngithub_pat_wiz\nn\nfile\n\n\ny\n' \
  | wizard >/dev/null 2>&1
expect_eq "answering the human's own login is re-asked, not fatal" "$?" "0"
expect_eq "and the agent account is what got set up" \
  "$(cfg identity.$USER_IDENT.login)" "patrick-agent"
unset FAKE_GH_LOGIN

# --wizard alongside flags asks only for what the flags did not answer, so the
# two ways of driving setup compose instead of one overriding the other.
new_sandbox
printf 'y\nok\n\n\ny\n' | "$ROOT/bin/guise" setup --wizard \
  --kind app --owner patricktulskie --app-id 1111 --pem "$SB/key.pem" \
  --store file >/dev/null 2>&1
expect_eq "--wizard with flags exits 0" "$?" "0"
expect_eq "the flags are taken, not re-asked" "$(cfg identity.$APP_IDENT.appid)" "1111"
expect_eq "including the store" "$(cfg identity.$APP_IDENT.keysource)" "file"

# A dumb terminal is still a terminal, so a bare setup runs the wizard -- but
# nothing it draws may need the cursor moved to take it back. util-linux and
# BSD script disagree on where the command goes, and util-linux runs it with
# $SHELL, which the sandbox points at a zsh that may not be installed. BSD
# script hands the pty an EOF the moment its stdin closes, so stdin is held open
# until the command is done. A watchdog turns a stuck pty into a failure
# instead of a hung job.
pty_script() {
  if script --version >/dev/null 2>&1; then SHELL=/bin/bash exec script -qec "$1" /dev/null
  else exec script -q /dev/null bash -c "$1"; fi
}
in_pty() { # "command" -- stdin is what gets typed
  local done="$SB/pty.done" pid watchdog rc=0
  mkfifo "$done"
  exec 3<&0
  { cat <&3; read -r _ < "$done"; } | pty_script "$1; : > '$done'" &
  pid=$!
  exec 3<&-
  ( sleep 30; kill "$pid"; : > "$done" ) 2>/dev/null &
  watchdog=$!
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null || true
  rm -f "$done"
  return $rc
}
new_sandbox
printf 'app\ny\npatricktulskie\n1111\n%s\nok\n\n\n\nn\n' "$SB/key.pem" \
  | TERM=dumb in_pty "'$ROOT/bin/guise' setup" > "$SB/dumb.out" 2>&1
grep -q "Look good?" "$SB/dumb.out" || sed 's/^/    | /' "$SB/dumb.out"
expect "a bare setup on a dumb terminal still runs the wizard" \
  grep -q "Look good?" "$SB/dumb.out"
expect_fail "without a single escape sequence" grep -q $'\033' "$SB/dumb.out"

# The wizard is what a bare setup does *on a terminal*. With no terminal there
# is nothing to ask, so the flag-driven refusal stands.
new_sandbox
expect_fail "a bare setup with no terminal still refuses rather than prompting" agent setup
expect "and writes no config" test ! -e "$HOME/.config/guise/config"
expect_fail "there is still no --token flag to pass" \
  agent setup --kind user --token github_pat_nope

# --- update ------------------------------------------------------------------
# Picking up a new version must work with the vault locked and the network down,
# which is the whole reason this exists instead of "just re-run setup".
echo "update:"
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >/dev/null 2>&1
awk '{print $1" "$2}' "$HOME/.config/guise/keys/$USER_IDENT.signing.pub" \
  >> "$SIGNING_KEYS_FILE"

confdir="$HOME/.config/guise/git"
cfgfile="$HOME/.config/guise/config"
cfg_before=$(shasum < "$cfgfile")
# Clobber everything update owns; leave everything it must not touch alone.
echo broken > "$HOME/.local/bin/guise-gh"
echo broken > "$HOME/.config/guise/hook.sh"
echo broken > "$HOME/.local/bin/guise-token"
echo broken > "$confdir/agent-hooks/prepare-commit-msg"
echo broken > "$confdir/$APP_IDENT.conf"
echo broken > "$confdir/$USER_IDENT.conf"
# The wiring too, or update could stop calling regen_owned_gitconfig and
# ensure_include_block and every assertion below would still pass. The alias
# stands in for whatever else the engineer keeps in ~/.gitconfig.
echo "# clobbered" > "$HOME/.config/guise/gitconfig"
cat > "$HOME/.gitconfig" <<'GITCONFIG'
[user]
	name = Human
	email = human@example.com
[commit]
	gpgsign = true
[init]
	defaultBranch = main
[alias]
	lg = log --oneline
GITCONFIG
: > "$CURL_LOG"
OP_FAKE_FORBID=1 agent update >/dev/null 2>&1
expect_eq "update exits 0 with 1Password refusing every call" "$?" "0"
expect_eq "and having made no API calls at all" "$(grep -c . "$CURL_LOG")" "0"
expect "guise-gh reinstalled" grep -q GH_TOKEN "$HOME/.local/bin/guise-gh"
expect "token helper reinstalled" grep -q 'guise-token' "$HOME/.local/bin/guise-token"
expect "commit hook reinstalled" grep -q 'Co-authored-by' "$confdir/agent-hooks/prepare-commit-msg"
expect "shell hook reinstalled" grep -q 'emit-shell' "$HOME/.config/guise/hook.sh"
expect_eq "config left byte-identical" "$(shasum < "$cfgfile")" "$cfg_before"
# A bare `setup` re-renders only the identity it ran for; update does all of them.
expect "app identity conf re-rendered" \
  grep -q '3333+test-agent\[bot\]@users\.noreply\.github\.com' "$confdir/$APP_IDENT.conf"
expect "user identity conf re-rendered too" \
  grep -q "4444+$USER_IDENT@users\.noreply\.github\.com" "$confdir/$USER_IDENT.conf"
expect "a signing identity still signs afterwards" \
  grep -q 'gpgsign = true' "$confdir/$USER_IDENT.conf"
owned="$HOME/.config/guise/gitconfig"
expect_eq "owned gitconfig regenerated, one includeIf per identity" \
  "$(grep -c includeIf "$owned")" "2"
# A count alone passes when both entries name the same identity, so pair each
# gitdir with the conf it has to load.
for id in "$APP_IDENT" "$USER_IDENT"; do
  expect_eq "the includeIf for '$id' loads its own conf" \
    "$(git config -f "$owned" --get "includeIf.gitdir:~/agentic-code/$id/.path" || echo MISSING)" \
    "git/$id.conf"
done
expect_eq "the managed include block is back in ~/.gitconfig" \
  "$(grep -cF '# >>> guise >>>' "$HOME/.gitconfig")" "1"
expect "unrelated global config survived" grep -q 'lg = log --oneline' "$HOME/.gitconfig"
expect_eq "and the human's own identity with it" \
  "$(git -C "$SB" config --get user.email)" "human@example.com"
wirerepo="$HOME/agentic-code/$APP_IDENT/rewired"
git init -q "$wirerepo"
expect_eq "the identity resolves inside its directory again" \
  "$(git -C "$wirerepo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
uprepo="$HOME/agentic-code/$USER_IDENT/afterupdate"
git init -q "$uprepo"
( cd "$uprepo" && echo x > f && git add f && git commit -q -m "after update" )
expect_eq "and commits made after an update still verify" \
  "$(git -C "$uprepo" log -1 --format='%G?')" "G"

# The installed copy is the thing being updated, so prove it actually moves.
echo '# stale' >> "$HOME/.local/bin/guise"
agent update >/dev/null 2>&1
expect "the installed script is replaced by the one being run" \
  cmp -s "$ROOT/bin/guise" "$HOME/.local/bin/guise"
snap_up=$(snapshot)
agent update >/dev/null 2>&1
expect_eq "a second update changes nothing" "$(snapshot)" "$snap_up"
OP_FAKE_FORBID=1 agent doctor >/dev/null 2>&1
expect_eq "doctor still passes after an update" "$?" "0"

expect_fail "update refuses arguments" agent update --name "$APP_IDENT"
rm -f "$cfgfile"
expect_fail "update refuses when there is no config" agent update

# --- uninstall restores prior state ------------------------------------------
echo "uninstall:"
new_sandbox
printf 'alias ll="ls -l"\n' > "$HOME/.zshrc"
cp "$HOME/.gitconfig" "$SB/gitconfig.pre"
cp "$HOME/.zshrc" "$SB/zshrc.pre"
run_setup --store op --pem "$SB/key.pem" >/dev/null 2>&1
"$ROOT/bin/guise" uninstall --yes >/dev/null 2>&1
expect_eq "uninstall exits 0" "$?" "0"
expect "~/.gitconfig byte-identical to pre-setup" cmp -s "$HOME/.gitconfig" "$SB/gitconfig.pre"
expect "~/.zshrc byte-identical to pre-setup" cmp -s "$HOME/.zshrc" "$SB/zshrc.pre"
expect "config dir removed" test ! -e "$HOME/.config/guise"
expect "token cache removed" test ! -e "$XDG_CACHE_HOME/guise"
expect "helpers removed" test ! -e "$HOME/.local/bin/guise-token"
expect "1Password item left alone" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "agent dir left alone" test -d "$HOME/agentic-code/$APP_IDENT"
expect_eq "human git identity unchanged" \
  "$(git config --global user.email)" "human@example.com"

# ------------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
