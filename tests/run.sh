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
  export FAKE_APP_ID=1111 FAKE_SLUG=test-agent FAKE_OWNER=patricktulskie FAKE_INSTALL_ID=2222 FAKE_BOT_ID=3333
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

snapshot() {
  cat "$HOME/.gitconfig" \
      "$HOME/.config/agent-id/config" \
      "$HOME/.config/agent-id/gitconfig" \
      "$HOME/.config/agent-id/git/default.conf" \
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
expect_eq "slug discovered from API" "$(cfg identity.default.slug)" "test-agent"
expect_eq "installation id discovered" "$(cfg identity.default.installationid)" "2222"
expect_eq "bot user id discovered (not app id)" "$(cfg identity.default.botuserid)" "3333"
expect_eq "basedir defaults to ~/agentic-code" "$(cfg core.basedir)" "$HOME/agentic-code"
expect "PEM shredded after storing" test ! -e "$SB/key.pem"
expect "private key landed in 1Password" test -f "$OP_FAKE_DIR/Private/test-agent/private_key"
expect "helpers installed" test -x "$HOME/.local/bin/agent-id-token"
expect "credential helper installed" test -x "$HOME/.local/bin/agent-id-credential"
expect "agent-gh installed" test -x "$HOME/.local/bin/agent-gh"
expect "hook installed" test -x "$HOME/.config/agent-id/git/agent-hooks/prepare-commit-msg"
expect "identity dir created" test -d "$HOME/agentic-code/default"
expect_eq "exactly one marker block in ~/.gitconfig" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.gitconfig")" "1"

# --- idempotency -------------------------------------------------------------
echo "idempotency:"
snap1=$(snapshot)
run_setup >/dev/null 2>&1
expect_eq "re-run without --pem exits 0" "$?" "0"
expect_eq "re-run changes no artifact" "$(snapshot)" "$snap1"
expect_eq "still exactly one marker block" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.gitconfig")" "1"

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

# --- identity applies inside scope, hook behaves -----------------------------
echo "scoped identity + trailer hook:"
repo="$HOME/agentic-code/default/hooktest"
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
t1=$("$HOME/.local/bin/agent-id-token" default)
t2=$("$HOME/.local/bin/agent-id-token" default)
expect_eq "second call returns cached token" "$t1" "$t2"
expect_eq "only one mint against the API" "$(grep -c access_tokens "$CURL_LOG")" "1"

# --- doctor ------------------------------------------------------------------
echo "doctor:"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes on a healthy install" "$?" "0"

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
expect "agent dir left alone" test -d "$HOME/agentic-code/default"
expect_eq "human git identity unchanged" \
  "$(git config --global user.email)" "human@example.com"

# ------------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
