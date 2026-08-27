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
  unset AGENT_ID_IDENTITY AGENT_ID_CONFIG AGENT_ID_CO_AUTHOR 2>/dev/null || true
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
  "$ROOT/bin/agent-id" setup --owner patricktulskie --app-id 1111 \
    --op-account my.1password.com "$@" </dev/null
}

run_setup_user() {
  "$ROOT/bin/agent-id" setup --kind user \
    --op-account my.1password.com "$@" </dev/null
}

agent() { "$ROOT/bin/agent-id" "$@" </dev/null; }

new_token_file() { printf 'github_pat_stub123\n' > "$1"; }

cfg() { git config -f "$HOME/.config/agent-id/config" --get "$1"; }

# setup names an identity after the account it belongs to, so these are the
# names the stubbed app slug and account login produce.
APP_IDENT=test-agent
USER_IDENT=patrick-agent

snapshot() {
  cat "$HOME/.gitconfig" \
      "$HOME/.zshrc" \
      "$HOME/.config/agent-id/hook.sh" \
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
expect "shell hook written" test -f "$HOME/.config/agent-id/hook.sh"
expect_eq "exactly one marker block in ~/.zshrc" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.zshrc")" "1"

# --- idempotency -------------------------------------------------------------
echo "idempotency:"
snap1=$(snapshot)
echo "custom rules" > "$HOME/agentic-code/AGENTS.md"
run_setup >/dev/null 2>&1
expect_eq "re-run without --pem exits 0" "$?" "0"
expect_eq "re-run changes no artifact" "$(snapshot)" "$snap1"
expect_eq "still exactly one marker block" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.gitconfig")" "1"
expect_eq "and the rc line is not stacked up either" \
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.zshrc")" "1"
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

# A missing global identity must not abort the commit: git config exits 1 on an
# unset key and the hook runs under set -e. Driven directly rather than through a
# commit, so unsetting the global identity can't reorder ~/.gitconfig and leave
# [user] winning over the include.
hook="$HOME/.config/agent-id/git/agent-hooks/prepare-commit-msg"
mkdir -p "$SB/nohome"
printf 'a commit subject\n' > "$SB/msg.txt"
( HOME="$SB/nohome" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "hook exits 0 when there is no identity to credit" "$?" "0"
expect_eq "and leaves the message without a trailer" \
  "$(grep -c '^Co-authored-by:' "$SB/msg.txt")" "0"
printf 'a commit subject\n' > "$SB/msg.txt"
( AGENT_ID_CO_AUTHOR="Someone <s@example.com>" "$hook" "$SB/msg.txt" ) >/dev/null 2>&1
expect_eq "and still adds the trailer when one is available" \
  "$(grep -c '^Co-authored-by: Someone <s@example.com>$' "$SB/msg.txt")" "1"

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
  "$(stat -c '%a' "$keyfile" 2>/dev/null || stat -f '%Lp' "$keyfile")" "600"
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
FAKE_STAT_GNU=1 "$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor reads app-key permissions with GNU stat semantics" "$?" "0"
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
  "$(stat -c '%a' "$tokenfile" 2>/dev/null || stat -f '%Lp' "$tokenfile")" "600"
expect "nothing written to 1Password" test ! -e "$OP_FAKE_DIR/Private/patrick-agent"
expect_eq "token helper reads the file" \
  "$("$HOME/.local/bin/agent-id-token" "$USER_IDENT")" "github_pat_filestore"
"$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor passes with a file-stored PAT" "$?" "0"
FAKE_STAT_GNU=1 "$ROOT/bin/agent-id" doctor >/dev/null 2>&1
expect_eq "doctor reads token permissions with GNU stat semantics" "$?" "0"

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
openssl genrsa -out "$SB/key3.pem" 2048 2>/dev/null
run_setup --store file --name claimed --pem "$SB/key3.pem" --default >/dev/null 2>&1
expect_eq "--default claims the default identity" "$(cfg core.defaultidentity)" "claimed"
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

# --- clone ---------------------------------------------------------------------
# Real git, no network: rewrite the github.com URL clone builds to a local bare
# repo, so what gets asserted is where the clone lands.
echo "clone:"
new_sandbox
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
openssl genrsa -out "$SB/key2.pem" 2048 2>/dev/null
run_setup --store file --name platform --pem "$SB/key2.pem" >/dev/null 2>&1
mkdir -p "$SB/origins/owner"
for r in one two three four; do git init -q --bare "$SB/origins/owner/$r.git"; done
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
printf '%s\n' "\${AGENT_ID_IDENTITY:-}" > "$SB/use.identity"
EOF
chmod +x "$SB/recording-shell"

SHELL="$SB/recording-shell" "$ROOT/bin/agent-id" use platform </dev/null >/dev/null 2>&1
expect_eq "use lands in the named identity's directory" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/platform"
# Nothing is exported: the directory is what carries the identity, so there is
# no stale variable to follow you out of the tree.
expect_eq "and exports nothing to go stale" "$(cat "$SB/use.identity")" ""

# The list is sorted, so 1 is 'platform' -- not the default, which is what makes
# the answer observable.
rm -f "$SB/use.pwd"
printf '1\n' | SHELL="$SB/recording-shell" "$ROOT/bin/agent-id" use >/dev/null 2>&1
expect_eq "picking by number selects that identity" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/platform"

rm -f "$SB/use.pwd"
SHELL="$SB/recording-shell" "$ROOT/bin/agent-id" use </dev/null >/dev/null 2>&1
expect_eq "no name and nothing to read falls back to the default" \
  "$(cat "$SB/use.pwd")" "$HOME/agentic-code/$APP_IDENT"

expect_fail "use refuses an unknown identity" agent use nonesuch

# The shell hook: `use --emit-shell` prints the cd, the sourced function runs it
# in the shell you are already in. Everything else falls through to the script.
expect_eq "--emit-shell prints just the cd, shell-quoted" \
  "$(agent use platform --emit-shell)" "cd '$HOME/agentic-code/platform'"
expect_eq "sourcing the hook makes use cd the running bash" \
  "$(PATH="$HOME/.local/bin:$PATH" bash -c \
      'cd "$HOME"; . "$HOME/.config/agent-id/hook.sh"; agent-id use platform; printf %s "$PWD"')" \
  "$HOME/agentic-code/platform"
expect_eq "and passes every other subcommand straight through" \
  "$(PATH="$HOME/.local/bin:$PATH" bash -c \
      '. "$HOME/.config/agent-id/hook.sh"; agent-id default')" \
  "$APP_IDENT"
expect_fail "and reports failure without moving the shell" \
  env PATH="$HOME/.local/bin:$PATH" bash -c \
      '. "$HOME/.config/agent-id/hook.sh"; agent-id use nonesuch'
if command -v zsh >/dev/null; then
  expect_eq "sourcing the hook makes use cd the running zsh" \
    "$(PATH="$HOME/.local/bin:$PATH" zsh -c \
        'cd "$HOME"; . "$HOME/.config/agent-id/hook.sh"; agent-id use platform; printf %s "$PWD"')" \
    "$HOME/agentic-code/platform"
else
  echo "  skip  sourcing the hook makes use cd the running zsh (zsh not installed)"
fi

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
signkey="$HOME/.config/agent-id/keys/$USER_IDENT.signing"
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
  "$HOME/.config/agent-id/git/$USER_IDENT.allowed_signers"

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
  test -f "$HOME/.config/agent-id/keys/gated.signing"
expect_eq "with signing on" "$(cfg identity.gated.signing)" "ssh"
run_setup_user --name gated --no-sign >/dev/null 2>&1
expect_eq "--no-sign exits 0" "$?" "0"
expect_fail "signing unset in config" cfg identity.gated.signing
expect_fail "signingkey unset too" cfg identity.gated.signingkey
expect "local private key shredded" test ! -e "$HOME/.config/agent-id/keys/gated.signing"
expect "public half removed with it" test ! -e "$HOME/.config/agent-id/keys/gated.signing.pub"
expect "allowed signers file removed" test ! -e "$HOME/.config/agent-id/git/gated.allowed_signers"
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
run_setup_user --name opsign --sign --token-file "$SB/pat3.txt" >/dev/null 2>&1
opkey="$HOME/.config/agent-id/keys/opsign.signing"
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
  "$(cfg identity.bot-renamed.signingkey)" "$HOME/.config/agent-id/keys/bot-renamed.signing"
expect "renamed private key exists" test -f "$HOME/.config/agent-id/keys/bot-renamed.signing"
expect "renamed public key exists" test -f "$HOME/.config/agent-id/keys/bot-renamed.signing.pub"
expect "stale allowed signers removed" \
  test ! -e "$HOME/.config/agent-id/git/$USER_IDENT.allowed_signers"
renamedsign="$HOME/agentic-code/bot-renamed/scoped"
git init -q "$renamedsign"
( cd "$renamedsign" && echo x > f && git add f && git commit -q -m "still signed" )
expect_eq "commits still verify under the new name" \
  "$(git -C "$renamedsign" log -1 --format='%G?')" "G"
# Signing keys are credentials like any other, so uninstall leaves them where
# they are -- same policy as the 1Password items and the on-disk PATs.
agent uninstall --yes >"$SB/uninstall.out" 2>&1
expect "uninstall leaves the signing key alone" \
  test -f "$HOME/.config/agent-id/keys/bot-renamed.signing"
expect "and names the public half still on the account" \
  grep -q 'public signing key on the agent account' "$SB/uninstall.out"

# --- update ------------------------------------------------------------------
# Picking up a new version must work with the vault locked and the network down,
# which is the whole reason this exists instead of "just re-run setup".
echo "update:"
new_sandbox
export FAKE_GH_LOGIN=PatrickTulskie
run_setup --store file --pem "$SB/key.pem" >/dev/null 2>&1
new_token_file "$SB/pat.txt"
run_setup_user --store file --sign --token-file "$SB/pat.txt" >/dev/null 2>&1
awk '{print $1" "$2}' "$HOME/.config/agent-id/keys/$USER_IDENT.signing.pub" \
  >> "$SIGNING_KEYS_FILE"

confdir="$HOME/.config/agent-id/git"
cfgfile="$HOME/.config/agent-id/config"
cfg_before=$(shasum < "$cfgfile")
# Clobber everything update owns; leave everything it must not touch alone.
echo broken > "$HOME/.local/bin/agent-gh"
echo broken > "$HOME/.config/agent-id/hook.sh"
echo broken > "$HOME/.local/bin/agent-id-token"
echo broken > "$confdir/agent-hooks/prepare-commit-msg"
echo broken > "$confdir/$APP_IDENT.conf"
echo broken > "$confdir/$USER_IDENT.conf"
# The wiring too, or update could stop calling regen_owned_gitconfig and
# ensure_include_block and every assertion below would still pass. The alias
# stands in for whatever else the engineer keeps in ~/.gitconfig.
echo "# clobbered" > "$HOME/.config/agent-id/gitconfig"
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
expect "agent-gh reinstalled" grep -q GH_TOKEN "$HOME/.local/bin/agent-gh"
expect "token helper reinstalled" grep -q 'agent-id-token' "$HOME/.local/bin/agent-id-token"
expect "commit hook reinstalled" grep -q 'Co-authored-by' "$confdir/agent-hooks/prepare-commit-msg"
expect "shell hook reinstalled" grep -q 'emit-shell' "$HOME/.config/agent-id/hook.sh"
expect_eq "config left byte-identical" "$(shasum < "$cfgfile")" "$cfg_before"
# A bare `setup` re-renders only the identity it ran for; update does all of them.
expect "app identity conf re-rendered" \
  grep -q '3333+test-agent\[bot\]@users\.noreply\.github\.com' "$confdir/$APP_IDENT.conf"
expect "user identity conf re-rendered too" \
  grep -q "4444+$USER_IDENT@users\.noreply\.github\.com" "$confdir/$USER_IDENT.conf"
expect "a signing identity still signs afterwards" \
  grep -q 'gpgsign = true' "$confdir/$USER_IDENT.conf"
owned="$HOME/.config/agent-id/gitconfig"
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
  "$(grep -cF '# >>> agent-id >>>' "$HOME/.gitconfig")" "1"
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
echo '# stale' >> "$HOME/.local/bin/agent-id"
agent update >/dev/null 2>&1
expect "the installed script is replaced by the one being run" \
  cmp -s "$ROOT/bin/agent-id" "$HOME/.local/bin/agent-id"
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
run_setup --pem "$SB/key.pem" >/dev/null 2>&1
"$ROOT/bin/agent-id" uninstall --yes >/dev/null 2>&1
expect_eq "uninstall exits 0" "$?" "0"
expect "~/.gitconfig byte-identical to pre-setup" cmp -s "$HOME/.gitconfig" "$SB/gitconfig.pre"
expect "~/.zshrc byte-identical to pre-setup" cmp -s "$HOME/.zshrc" "$SB/zshrc.pre"
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
