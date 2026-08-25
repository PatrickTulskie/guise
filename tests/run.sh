#!/usr/bin/env bash
# Shell test harness (bats not assumed). Runs everything in a sandboxed $HOME
# with stubbed `op` and `curl`; git, openssl, jq, shred are the real ones.
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

new_sandbox() {
  SB=$(mktemp -d)
  export HOME="$SB/home"
  mkdir -p "$HOME"
  export XDG_CACHE_HOME="$HOME/.cache"
  export OP_FAKE_DIR="$SB/op"; mkdir -p "$OP_FAKE_DIR"
  export CURL_LOG="$SB/curl.log"; : > "$CURL_LOG"
  export PATH="$ROOT/tests/stubs:$REAL_PATH"
  export FAKE_APP_ID=1111 FAKE_SLUG=test-agent FAKE_OWNER=PatrickTulskie FAKE_INSTALL_ID=2222 FAKE_BOT_ID=3333
  export FAKE_USER_ID=4444 FAKE_LOGIN=patrick-agent
  unset FAKE_GH_LOGIN FAKE_TOKEN_EXPIRES 2>/dev/null || true
  export OP_FAKE_ACCOUNT=my.1password.com
  unset AGENT_ID_IDENTITY AGENT_ID_CONFIG AGENT_ID_CO_AUTHOR 2>/dev/null || true
  git config --global user.name "Human"
  git config --global user.email "human@example.com"
  git config --global commit.gpgsign true
  git config --global init.defaultBranch main
  openssl genrsa -out "$SB/key.pem" 2048 2>/dev/null
}

# No --coauthor: the hook's fallback to global user.name/email is under test.
run_setup() {
  "$ROOT/bin/agent-id" setup --owner patricktulskie --app-id 1111 \
    --op-account my.1password.com "$@" </dev/null
}

cfg() { git config -f "$HOME/.config/agent-id/config" --get "$1"; }

# setup names an identity after the account it belongs to, so these are the
# names the stubbed app slug and account login produce.
APP_IDENT=test-agent
USER_IDENT=patrick-agent

snapshot() {
  cat "$HOME/.gitconfig" \
      "$HOME/.config/agent-id/config" \
      "$HOME/.config/agent-id/gitconfig" \
      "$HOME/.config/agent-id/git/$APP_IDENT.conf" \
      "$HOME/.config/agent-id/git/agent-hooks/prepare-commit-msg" \
      "$HOME/.local/bin/agent-id-token" \
      "$HOME/.local/bin/agent-id-credential" \
      "$HOME/.local/bin/agent-gh" 2>/dev/null | shasum | cut -d' ' -f1
}

# --- setup provisions everything --------------------------------------------
echo "setup:"
new_sandbox
run_setup --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "setup exits 0" "$?" "0"
expect "config file written" test -f "$HOME/.config/agent-id/config"
expect_eq "slug discovered from API" "$(cfg identity.$APP_IDENT.slug)" "test-agent"
expect_eq "installation id discovered" "$(cfg identity.$APP_IDENT.installationid)" "2222"
expect_eq "bot user id discovered (not app id)" "$(cfg identity.$APP_IDENT.botuserid)" "3333"
expect_eq "basedir defaults to ~/agentic-code" "$(cfg core.basedir)" "$HOME/agentic-code"
expect "PEM shredded after storing" test ! -e "$SB/key.pem"
expect "private key landed in 1Password" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "helpers installed" test -x "$HOME/.local/bin/agent-id-token"
expect "credential helper installed" test -x "$HOME/.local/bin/agent-id-credential"
expect "agent-gh installed" test -x "$HOME/.local/bin/agent-gh"
expect "hook installed" test -x "$HOME/.config/agent-id/git/agent-hooks/prepare-commit-msg"
expect "identity dir created" test -d "$HOME/agentic-code/$APP_IDENT"
expect "AGENTS.md dropped in workspace" test -f "$HOME/agentic-code/AGENTS.md"
expect "CLAUDE.md imports AGENTS.md" grep -q '@AGENTS.md' "$HOME/agentic-code/CLAUDE.md"
expect_eq "exactly one marker block in ~/.gitconfig" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.gitconfig")" "1"

# --- idempotency -------------------------------------------------------------
echo "idempotency:"
snap1=$(snapshot)
echo "custom rules" > "$HOME/agentic-code/AGENTS.md"
run_setup >/dev/null 2>&1
expect_eq "re-run without --pem exits 0" "$?" "0"
expect_eq "re-run changes no artifact" "$(snapshot)" "$snap1"
expect_eq "still exactly one marker block" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.gitconfig")" "1"
expect_eq "edited AGENTS.md not overwritten" \
  "$(cat "$HOME/agentic-code/AGENTS.md")" "custom rules"

# --- second identity ---------------------------------------------------------
echo "multiple identities:"
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
expect_eq "second identity setup exits 0" "$?" "0"
expect_eq "two includeIf blocks in owned gitconfig" \
  "$(grep -c includeIf "$HOME/.config/agent-id/gitconfig")" "2"
expect_eq "~/.gitconfig untouched by second identity" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.gitconfig")" "1"
expect "platform dir created" test -d "$HOME/agentic-code/platform"
run_setup --name reused >/dev/null 2>&1
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

# --- token cache -------------------------------------------------------------
echo "token cache:"
rm -rf "$XDG_CACHE_HOME/agent-id"; : > "$CURL_LOG"
t1=$("$HOME/.local/bin/agent-id-token" "$APP_IDENT")
t2=$("$HOME/.local/bin/agent-id-token" "$APP_IDENT")
expect_eq "second call returns cached token" "$t1" "$t2"
expect_eq "only one mint against the API" "$(grep -c access_tokens "$CURL_LOG")" "1"

# --- doctor ------------------------------------------------------------------
echo "doctor:"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes on a healthy install" "$?" "0"

# A valid credential that reaches zero repos passes every other check and only
# fails at clone time -- doctor has to catch it.
FAKE_REPO_COUNT=0 "$ROOT/bin/agent-id" doctor > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when the installation reaches no repos" "$?" "1"
expect "the failure names the installation reachability check" \
  grep -q "FAIL  installation reaches at least one repository" "$SB/doctor.out"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes again once the installation has a repo" "$?" "0"

# --- file key store ----------------------------------------------------------
echo "file key store:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "file-store setup exits 0" "$?" "0"
keyfile="$HOME/.config/agent-id/keys/$APP_IDENT.pem"
expect "key file written" test -f "$keyfile"
expect_eq "key file mode 600" \
  "$(stat -f '%Lp' "$keyfile" 2>/dev/null || stat -c '%a' "$keyfile")" "600"
expect_eq "keysource recorded" "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "nothing written to 1Password" test ! -e "$OP_FAKE_DIR/Private/test-agent"
expect "PEM shredded after storing" test ! -e "$SB/key.pem"
t=$("$HOME/.local/bin/agent-id-token" "$APP_IDENT")
expect_eq "token mints from file key" "${t:0:4}" "ghs_"
run_setup >/dev/null 2>&1
expect_eq "re-run without --store keeps the file store" "$(cfg identity.$APP_IDENT.keysource)" "file"
expect "re-run did not move the key into 1Password" test ! -e "$OP_FAKE_DIR/Private/test-agent"
run_setup --store file --name second >/dev/null 2>&1
expect_eq "second file identity reuses key without --pem" "$?" "0"
expect "second identity got its own key file" test -f "$HOME/.config/agent-id/keys/second.pem"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes with file store" "$?" "0"
"$ROOT/bin/agent-id" uninstall --yes >/dev/null 2>&1
expect "uninstall keeps key files" test -f "$keyfile"
expect "uninstall removes config file" test ! -e "$HOME/.config/agent-id/config"
expect "uninstall removes rendered git dir" test ! -e "$HOME/.config/agent-id/git"

# --- user account identity ---------------------------------------------------
echo "user account identity:"
new_sandbox
printf 'github_pat_stub123\n' > "$SB/pat.txt"
"$ROOT/bin/agent-id" setup --kind user --token-file "$SB/pat.txt" \
  --op-account my.1password.com </dev/null >/dev/null 2>&1
expect_eq "user setup exits 0" "$?" "0"
expect_eq "kind recorded" "$(cfg identity.$USER_IDENT.kind)" "user"
expect_eq "login discovered from the token" "$(cfg identity.$USER_IDENT.login)" "patrick-agent"
expect_eq "user id discovered" "$(cfg identity.$USER_IDENT.userid)" "4444"
expect_eq "token expiry recorded" \
  "$(cfg identity.$USER_IDENT.tokenexpires)" "2099-01-01 00:00:00 UTC"
expect "token stored in 1Password" test -f "$OP_FAKE_DIR/Private/patrick-agent/token"
expect "token file shredded" test ! -e "$SB/pat.txt"
expect_eq "token helper returns the PAT verbatim" \
  "$("$HOME/.local/bin/agent-id-token" "$USER_IDENT")" "github_pat_stub123"
expect "PAT is not cached to disk" test ! -e "$XDG_CACHE_HOME/agent-id/$USER_IDENT.token.json"

repo="$HOME/agentic-code/$USER_IDENT/usertest"
git init -q "$repo"
expect_eq "account identity applies inside scope" \
  "$(git -C "$repo" config --get user.email)" "4444+patrick-agent@users.noreply.github.com"
expect_eq "commits are authored by the account, not a bot" \
  "$(git -C "$repo" config --get user.name)" "patrick-agent"
"$ROOT/bin/agent-id" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor passes for a user identity" "$?" "0"

FAKE_REPO_COUNT=0 "$ROOT/bin/agent-id" doctor --name "$USER_IDENT" > "$SB/doctor.out" 2>&1
expect_eq "doctor fails when the PAT reaches no repos" "$?" "1"
expect "the failure names the token reachability check" \
  grep -q "FAIL  token reaches at least one repository" "$SB/doctor.out"
"$ROOT/bin/agent-id" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor passes again once the PAT reaches a repo" "$?" "0"

"$ROOT/bin/agent-id" setup --kind user </dev/null >/dev/null 2>&1
expect_eq "re-run without --token-file reuses the stored token" "$?" "0"

# App and user identities have to coexist: they share basedir and ~/.gitconfig.
run_setup --name bot --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "app identity alongside a user identity" "$?" "0"
expect_eq "both identities in the owned gitconfig" \
  "$(grep -c includeIf "$HOME/.config/agent-id/gitconfig")" "2"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes with both kinds present" "$?" "0"

# --- user identity guardrails ------------------------------------------------
echo "user identity guardrails:"
printf 'github_pat_other\n' > "$SB/pat2.txt"
FAKE_GH_LOGIN=patrick-agent "$ROOT/bin/agent-id" setup --kind user --name mine \
  --token-file "$SB/pat2.txt" </dev/null >/dev/null 2>&1
expect_eq "refuses a token for your own account" "$?" "1"
expect "refused setup leaves the token file alone" test -f "$SB/pat2.txt"
"$ROOT/bin/agent-id" setup --kind user --name mine --login someone-else \
  --token-file "$SB/pat2.txt" </dev/null >/dev/null 2>&1
expect_eq "refuses a token that isn't the --login account" "$?" "1"
"$ROOT/bin/agent-id" setup --kind user --name mine --app-id 1111 </dev/null >/dev/null 2>&1
expect_eq "rejects app-only flags on a user identity" "$?" "1"
git config -f "$HOME/.config/agent-id/config" identity.$USER_IDENT.tokenexpires "2000-01-01 00:00:00 UTC"
"$ROOT/bin/agent-id" doctor --name "$USER_IDENT" >/dev/null 2>&1
expect_eq "doctor fails on a PAT inside its last 30 days" "$?" "1"

# --- user identity with the file store ---------------------------------------
echo "user identity, file store:"
new_sandbox
printf 'github_pat_filestore\n' > "$SB/pat.txt"
"$ROOT/bin/agent-id" setup --kind user --store file --token-file "$SB/pat.txt" \
  </dev/null >/dev/null 2>&1
expect_eq "file-store user setup exits 0" "$?" "0"
tokenfile="$HOME/.config/agent-id/keys/$USER_IDENT.token"
expect "token file written" test -f "$tokenfile"
expect_eq "token file mode 600" \
  "$(stat -f '%Lp' "$tokenfile" 2>/dev/null || stat -c '%a' "$tokenfile")" "600"
expect "nothing written to 1Password" test ! -e "$OP_FAKE_DIR/Private/patrick-agent"
expect_eq "token helper reads the file" \
  "$("$HOME/.local/bin/agent-id-token" "$USER_IDENT")" "github_pat_filestore"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes with a file-stored PAT" "$?" "0"

# The store is settled only after the identity name is, so an unrelated
# file-store default can't quietly route a new App's private key to disk.
run_setup --pem "$SB/key.pem" >/dev/null 2>&1
expect_eq "app setup alongside a file-store default exits 0" "$?" "0"
expect_eq "new identity does not inherit the default's file store" \
  "$(cfg identity.$APP_IDENT.keysource)" "op"
expect "new identity's key went to 1Password" \
  test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "new identity's key not written to disk" \
  test ! -e "$HOME/.config/agent-id/keys/$APP_IDENT.pem"
run_setup >/dev/null 2>&1
expect_eq "re-running the app identity keeps 1Password" \
  "$(cfg identity.$APP_IDENT.keysource)" "op"
"$ROOT/bin/agent-id" setup --kind user </dev/null >/dev/null 2>&1
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
expect_eq "'default' subcommand reports it" "$("$ROOT/bin/agent-id" default)" "test-agent"
expect_eq "token with no identity resolves the default" \
  "$("$HOME/.local/bin/agent-id-token")" "$("$HOME/.local/bin/agent-id-token" test-agent)"

openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name explicit --pem "$SB/key2.pem" >/dev/null 2>&1
expect "--name still wins over the derived name" test -d "$HOME/agentic-code/explicit"
expect_eq "a later identity does not steal the default" "$(cfg core.defaultidentity)" "test-agent"
"$ROOT/bin/agent-id" default explicit >/dev/null 2>&1
expect_eq "default can be repointed" "$(cfg core.defaultidentity)" "explicit"
"$ROOT/bin/agent-id" default nonesuch >/dev/null 2>&1
expect_eq "default rejects an unknown identity" "$?" "1"

# --- rename -------------------------------------------------------------------
echo "rename:"
"$ROOT/bin/agent-id" default test-agent >/dev/null 2>&1
mkdir -p "$HOME/agentic-code/test-agent/someclone"
"$ROOT/bin/agent-id" rename test-agent renamed >/dev/null 2>&1
expect_eq "rename exits 0" "$?" "0"
expect "clones move with the identity" test -d "$HOME/agentic-code/renamed/someclone"
expect "old directory is gone" test ! -e "$HOME/agentic-code/test-agent"
expect_eq "config section renamed" "$(cfg identity.renamed.slug)" "test-agent"
expect_eq "old config section gone" "$(cfg identity.test-agent.slug 2>/dev/null)" ""
expect "key file renamed" test -f "$HOME/.config/agent-id/keys/renamed.pem"
expect_eq "keyfile path updated" \
  "$(cfg identity.renamed.keyfile)" "$HOME/.config/agent-id/keys/renamed.pem"
expect "rendered conf renamed" test -f "$HOME/.config/agent-id/git/renamed.conf"
expect "old rendered conf gone" test ! -e "$HOME/.config/agent-id/git/test-agent.conf"
expect_eq "default follows the rename" "$(cfg core.defaultidentity)" "renamed"
git init -q "$HOME/agentic-code/renamed/newrepo"
expect_eq "identity applies under the new directory" \
  "$(git -C "$HOME/agentic-code/renamed/newrepo" config --get user.email)" \
  "3333+test-agent[bot]@users.noreply.github.com"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes after rename" "$?" "0"
"$ROOT/bin/agent-id" rename renamed explicit >/dev/null 2>&1
expect_eq "rename refuses a name already in use" "$?" "1"
"$ROOT/bin/agent-id" rename nonesuch whatever >/dev/null 2>&1
expect_eq "rename refuses an unknown identity" "$?" "1"

# --- uninstall restores prior state ------------------------------------------
echo "uninstall:"
new_sandbox
cp "$HOME/.gitconfig" "$SB/gitconfig.pre"
run_setup --pem "$SB/key.pem" >/dev/null 2>&1
"$ROOT/bin/agent-id" uninstall --yes >/dev/null 2>&1
expect_eq "uninstall exits 0" "$?" "0"
expect "~/.gitconfig byte-identical to pre-setup" cmp -s "$HOME/.gitconfig" "$SB/gitconfig.pre"
expect "config dir removed" test ! -e "$HOME/.config/agent-id"
expect "token cache removed" test ! -e "$XDG_CACHE_HOME/agent-id"
expect "helpers removed" test ! -e "$HOME/.local/bin/agent-id-token"
expect "1Password item left alone" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "agent dir left alone" test -d "$HOME/agentic-code/$APP_IDENT"
expect_eq "human git identity unchanged" \
  "$(git config --global user.email)" "human@example.com"

# ------------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
